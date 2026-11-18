#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 05_teste_falha.sh
#  Testes de falha (resiliência) para o vídeo e para as evidências.
# -----------------------------------------------------------------------------
#  Testes disponíveis:
#   api      kill -9 no processo da API  -> systemd reinicia sozinho
#   monitor  kill -9 no monitor          -> systemd reinicia sozinho
#   cpu      estresse de CPU             -> monitor gera alerta WARN/CRIT
#   disco    arquivo temporário grande   -> monitor gera alerta de disco (e apaga)
#   mysql    para o MySQL                -> /health 503 + alerta CRIT -> restaura
#
#  Uso:
#   sudo ./scripts/05_teste_falha.sh            # roda todos, em sequência
#   sudo ./scripts/05_teste_falha.sh api mysql  # só os escolhidos
#
#  Tudo é registrado em /var/log/sombraviva/05_teste_falha.log
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "05_teste_falha" "$@"
log_banner "05 · Testes de falha e recuperação"

MONITOR="/opt/sombraviva/scripts/03_monitor.sh"
[[ -x "$MONITOR" ]] || MONITOR="$SCRIPT_DIR/03_monitor.sh"
HEALTH="http://127.0.0.1/health"
ARQ_DISCO="/var/tmp/sombraviva_teste_disco.img"
DURACAO_CPU="${DURACAO_CPU:-25}"
FOLGA_DISCO_MB="${FOLGA_DISCO_MB:-512}"   # nunca deixa o disco com menos que isso livre
PIDS_STRESS=()
MYSQL_PARADO=0
RESULTADOS=()

# Garante que NADA fique quebrado se o script for interrompido (Ctrl+C)
sv_cleanup() {
  local pid
  for pid in "${PIDS_STRESS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  pkill -f "stress-ng --cpu" 2>/dev/null || true
  rm -f "$ARQ_DISCO"
  if ((MYSQL_PARADO)); then
    systemctl start mysql || true
  fi
}

agora() { date '+%H:%M:%S'; }
codigo_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$HEALTH" || true; }

# Espera até que a condição (comando) seja verdadeira, por N segundos
esperar() {
  local limite="$1"; shift
  local i
  for ((i = 0; i < limite; i++)); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

registrar() {  # registrar "teste" "PASSOU|FALHOU" "detalhe"
  RESULTADOS+=("$(printf '%-8s %-7s %s' "$1" "$2" "$3")")
  audit "TESTE_FALHA teste=$1 resultado=$2 detalhe='$3'"
  if [[ "$2" == "PASSOU" ]]; then log_ok "[$1] $3"; else log_error "[$1] $3"; fi
}

# ------------------------------------------------------- kill -9 genérico ---
testar_kill() {
  local nome="$1" unidade="$2"
  log_step "Teste '$nome': kill -9 em $unidade"
  local pid_antes restarts_antes
  pid_antes="$(systemctl show -p MainPID --value "$unidade")"
  restarts_antes="$(systemctl show -p NRestarts --value "$unidade")"
  if [[ -z "$pid_antes" || "$pid_antes" == "0" ]]; then
    registrar "$nome" "FALHOU" "$unidade não está rodando"
    return 0
  fi
  log_info "[$(agora)] PID atual: $pid_antes | reinícios até agora: $restarts_antes"
  log_warn "[$(agora)] Enviando SIGKILL (kill -9 $pid_antes)…"
  kill -9 "$pid_antes"
  sleep 1
  log_info "[$(agora)] Estado logo após o kill: $(systemctl is-active "$unidade" || true)"
  # shellcheck disable=SC2317
  novo_pid_ok() {
    local p
    p="$(systemctl show -p MainPID --value "$unidade")"
    [[ "$p" != "0" && "$p" != "$pid_antes" ]] && systemctl is-active --quiet "$unidade"
  }
  if esperar 20 novo_pid_ok; then
    local pid_depois restarts_depois
    pid_depois="$(systemctl show -p MainPID --value "$unidade")"
    restarts_depois="$(systemctl show -p NRestarts --value "$unidade")"
    log_info "[$(agora)] Novo PID: $pid_depois | reinícios: $restarts_depois"
    journalctl -u "$unidade" --since "-1min" --no-pager -n 6 2>/dev/null | sed 's/^/      /' >&2 || true
    if [[ "$unidade" == "sombraviva-api.service" ]]; then
      esperar 15 bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 $HEALTH) == 200 ]]" || true
      log_info "[$(agora)] GET /health -> HTTP $(codigo_health)"
    fi
    registrar "$nome" "PASSOU" "PID $pid_antes morto, systemd reiniciou como PID $pid_depois (NRestarts $restarts_antes -> $restarts_depois)"
  else
    registrar "$nome" "FALHOU" "$unidade não voltou em 20 s"
  fi
}

# ------------------------------------------------------------------ CPU -----
testar_cpu() {
  log_step "Teste 'cpu': estresse de CPU por ${DURACAO_CPU}s"
  local inicio n
  inicio="$(date '+%Y-%m-%d %H:%M:%S')"
  n="$(nproc)"
  if command -v stress-ng >/dev/null 2>&1; then
    log_info "[$(agora)] stress-ng --cpu $n --timeout ${DURACAO_CPU}s"
    stress-ng --cpu "$n" --timeout "${DURACAO_CPU}s" >/dev/null 2>&1 &
    PIDS_STRESS+=("$!")
  else
    log_info "[$(agora)] stress-ng não instalado — usando $n processos 'yes' (sudo apt install stress-ng para a versão completa)"
    local i
    for ((i = 0; i < n; i++)); do
      timeout "${DURACAO_CPU}s" yes >/dev/null &
      PIDS_STRESS+=("$!")
    done
  fi
  sleep 5
  log_info "[$(agora)] Rodando o monitor durante o estresse:"
  "$MONITOR" --once 2>&1 | grep -E 'CPU' >&2 || true
  log_info "Aguardando o fim do estresse (o serviço de monitoramento também registra)…"
  wait "${PIDS_STRESS[@]}" 2>/dev/null || true
  PIDS_STRESS=()
  local alertas
  alertas="$(awk -v ini="$inicio" '$0 >= ini && /CPU/ && /\[(WARN|CRIT)\]/' "$LOG_DIR/monitor.log" 2>/dev/null | tail -n 5)"
  if [[ -n "$alertas" ]]; then
    printf '%s\n' "$alertas" | sed 's/^/      /' >&2
    registrar "cpu" "PASSOU" "alerta de CPU registrado em monitor.log e no syslog"
  else
    registrar "cpu" "FALHOU" "nenhum alerta de CPU (limite CPU_WARN alto demais para esta VM?)"
  fi
}

# ---------------------------------------------------------------- disco -----
testar_disco() {
  log_step "Teste 'disco': arquivo temporário até passar o limite de alerta"
  local warn total_kb usado_kb livre_kb alvo_kb precisa_kb inicio
  warn="$(awk -F= '/^DISCO_WARN=/ {print $2}' /etc/sombraviva/monitor.conf 2>/dev/null || true)"
  warn="${warn:-80}"
  inicio="$(date '+%Y-%m-%d %H:%M:%S')"
  read -r total_kb usado_kb livre_kb < <(df -Pk /var/tmp | awk 'NR==2 {print $2, $3, $4}')
  alvo_kb=$(( total_kb * (warn + 2) / 100 ))
  precisa_kb=$(( alvo_kb - usado_kb ))
  log_info "[$(agora)] Disco: $((usado_kb * 100 / total_kb))% usado, limite WARN ${warn}%"
  if (( precisa_kb <= 0 )); then
    log_info "Disco já está acima do limite — o monitor já deve estar alertando"
  elif (( precisa_kb > livre_kb - FOLGA_DISCO_MB * 1024 )); then
    log_warn "Encher o disco deixaria menos de ${FOLGA_DISCO_MB}MB livres — usando limite temporário"
    log_info "[$(agora)] Simulação: DISCO_WARN=1 (só nesta execução do monitor)"
    DISCO_WARN=1 DISCO_CRIT=99 "$MONITOR" --once 2>&1 | grep DISCO >&2 || true
  else
    log_warn "[$(agora)] Criando $ARQ_DISCO com $((precisa_kb / 1024)) MB (fallocate)…"
    fallocate -l "$((precisa_kb))K" "$ARQ_DISCO" 2>/dev/null || \
      dd if=/dev/zero of="$ARQ_DISCO" bs=1M count="$((precisa_kb / 1024))" status=none
    df -h /var/tmp | sed 's/^/      /' >&2
    "$MONITOR" --once 2>&1 | grep DISCO >&2 || true
    rm -f "$ARQ_DISCO"
    log_ok "[$(agora)] Arquivo removido — disco: $(df -P /var/tmp | awk 'NR==2 {print $5}')"
    "$MONITOR" --once 2>&1 | grep DISCO >&2 || true
  fi
  if awk -v ini="$inicio" '$0 >= ini && /DISCO/ && /\[(WARN|CRIT)\]/' "$LOG_DIR/monitor.log" | grep -q .; then
    registrar "disco" "PASSOU" "alerta de disco registrado e arquivo temporário removido"
  else
    registrar "disco" "FALHOU" "nenhum alerta de disco encontrado"
  fi
}

# ---------------------------------------------------------------- MySQL -----
testar_mysql() {
  log_step "Teste 'mysql': banco fora do ar"
  log_info "[$(agora)] Antes: GET /health -> HTTP $(codigo_health)"
  log_warn "[$(agora)] systemctl stop mysql"
  MYSQL_PARADO=1
  systemctl stop mysql
  sleep 2
  local codigo
  codigo="$(codigo_health)"
  log_info "[$(agora)] Com o banco parado: GET /health -> HTTP $codigo"
  curl -s --max-time 3 "$HEALTH" | sed 's/^/      /' >&2 || true
  echo >&2
  "$MONITOR" --once 2>&1 | grep -E 'API|MYSQL|SERVICO' >&2 || true
  log_info "[$(agora)] Restaurando: systemctl start mysql"
  systemctl start mysql
  MYSQL_PARADO=0
  # shellcheck disable=SC2317
  health_200() { [[ "$(codigo_health)" == "200" ]]; }
  if esperar 30 health_200; then
    log_info "[$(agora)] Depois: GET /health -> HTTP 200 (a API reconectou sozinha)"
    if [[ "$codigo" == "503" ]]; then
      registrar "mysql" "PASSOU" "/health foi 503 com o banco parado, alerta CRIT gerado e voltou a 200"
    else
      registrar "mysql" "FALHOU" "/health deveria ser 503 com o banco parado (foi $codigo)"
    fi
  else
    registrar "mysql" "FALHOU" "a API não voltou a responder 200 após religar o MySQL"
  fi
}

resumo() {
  log_step "Resumo dos testes ($(date '+%d/%m/%Y %H:%M:%S'))"
  local linha
  for linha in "${RESULTADOS[@]}"; do
    if [[ "$linha" == *PASSOU* ]]; then
      printf '  %s✔ %s%s\n' "$C_VERDE" "$linha" "$C_RESET" >&2
    else
      printf '  %s✖ %s%s\n' "$C_VERMELHO" "$linha" "$C_RESET" >&2
    fi
    printf '%s [RESULT] %s\n' "$(_sv_ts)" "$linha" >>"$LOG_FILE"
  done
  log_info "Evidências: $LOG_FILE, $LOG_DIR/monitor.log, $LOG_DIR/alertas.log"
  log_info "journalctl -u sombraviva-api -u sombraviva-monitor --since '-15min'"
}

main() {
  local testes=("$@")
  ((${#testes[@]})) || testes=(api monitor cpu disco mysql)
  local t
  for t in "${testes[@]}"; do
    case "$t" in
      api)     testar_kill "api" "sombraviva-api.service" ;;
      monitor) testar_kill "monitor" "sombraviva-monitor.service" ;;
      cpu)     testar_cpu ;;
      disco)   testar_disco ;;
      mysql)   testar_mysql ;;
      *) log_warn "Teste desconhecido: $t (use: api monitor cpu disco mysql)" ;;
    esac
  done
  resumo
}

main "$@"
