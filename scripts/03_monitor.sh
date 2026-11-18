#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 03_monitor.sh
#  Rubrica: "Script de monitoramento com alertas de CPU, disco e memória" (2 pts)
# -----------------------------------------------------------------------------
#  Verifica, a cada ciclo:
#   * CPU (% de uso medido em /proc/stat), memória (MemAvailable) e disco (df)
#     comparando com os limites WARN/CRIT de config/monitor.conf
#   * a saúde da aplicação: GET /health da API (que testa o MySQL)
#   * se os serviços systemd (sombraviva-api, nginx, mysql) estão ativos
#
#  Cada resultado vira uma linha com nível INFO / WARN / CRIT em:
#   * /var/log/sombraviva/monitor.log   (todas as verificações)
#   * /var/log/sombraviva/alertas.log   (só WARN e CRIT)
#   * syslog / journal (tag sombraviva-monitor) via 'logger'
#
#  Uso:
#   ./03_monitor.sh                 # um ciclo (padrão)
#   ./03_monitor.sh --loop          # contínuo, intervalo do monitor.conf
#   ./03_monitor.sh --loop 10       # contínuo a cada 10 s
#   LOG_DIR=/tmp/svlogs ./03_monitor.sh   # modo usuário/teste, sem root
#
#  Em produção ele roda como serviço: sombraviva-monitor.service (04_setup_monitoring.sh)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

# Valores definidos no AMBIENTE têm prioridade sobre o arquivo .conf
# (útil nos testes, ex.:  CPU_WARN=1 ./03_monitor.sh). Captura antes dos padrões.
declare -A _ENV_OVERRIDE=()
for _v in INTERVALO CPU_WARN CPU_CRIT MEM_WARN MEM_CRIT DISCO_WARN DISCO_CRIT DISCO_PONTOS \
          HEALTH_URL HEALTH_TIMEOUT SERVICOS ALERTA_WEBHOOK_URL; do
  if [[ -n "${!_v:-}" ]]; then
    _ENV_OVERRIDE[$_v]="${!_v}"
  fi
done

# ---------------------------------------------------------------- padrões ----
INTERVALO=30
CPU_WARN=75;   CPU_CRIT=90
MEM_WARN=80;   MEM_CRIT=92
DISCO_WARN=80; DISCO_CRIT=90
DISCO_PONTOS="/"
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_TIMEOUT=5
SERVICOS="sombraviva-api nginx mysql"
ALERTA_WEBHOOK_URL=""

if [[ -n "${MONITOR_CONF:-}" ]]; then
  CONF="$MONITOR_CONF"
elif [[ -f /etc/sombraviva/monitor.conf ]]; then
  CONF="/etc/sombraviva/monitor.conf"
else
  CONF="$REPO_DIR/config/monitor.conf"
fi

MODO="unico"
case "${1:-}" in
  --loop)    MODO="loop"; [[ -n "${2:-}" ]] && INTERVALO_CLI="$2" ;;
  --once|"") MODO="unico" ;;
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "Opção inválida: $1 (use --once, --loop [segundos] ou --help)" >&2; exit 64 ;;
esac

log_init "03_monitor" "$@"
load_conf "$CONF"
for _v in "${!_ENV_OVERRIDE[@]}"; do
  printf -v "$_v" '%s' "${_ENV_OVERRIDE[$_v]}"
done
[[ -n "${INTERVALO_CLI:-}" ]] && INTERVALO="$INTERVALO_CLI"
MONITOR_LOG="$LOG_DIR/monitor.log"
ALERTAS_LOG="$LOG_DIR/alertas.log"
PIOR=0   # 0 = INFO, 1 = WARN, 2 = CRIT (pior nível do ciclo)

# ----------------------------------------------------------- registrar -------
# alerta NIVEL CATEGORIA "mensagem"
alerta() {
  local nivel="$1" categoria="$2" msg="$3" ts cor prioridade
  ts="$(_sv_ts)"
  case "$nivel" in
    INFO) cor="$C_VERDE";    prioridade="user.info" ;;
    WARN) cor="$C_AMARELO";  prioridade="user.warning"; ((PIOR < 1)) && PIOR=1 ;;
    CRIT) cor="$C_VERMELHO"; prioridade="user.crit";    PIOR=2 ;;
  esac
  local linha
  linha="$(printf '%s [%-4s] %-8s %s' "$ts" "$nivel" "$categoria" "$msg")"
  printf '%s%s%s\n' "$cor" "$linha" "$C_RESET" >&2
  printf '%s\n' "$linha" >>"$MONITOR_LOG" 2>/dev/null || true
  if [[ "$nivel" != "INFO" ]]; then
    printf '%s\n' "$linha" >>"$ALERTAS_LOG" 2>/dev/null || true
  fi
  if command -v logger >/dev/null 2>&1; then
    logger -t sombraviva-monitor -p "$prioridade" -- "[$nivel] $categoria $msg" 2>/dev/null || true
  fi
  if [[ "$nivel" == "CRIT" && -n "$ALERTA_WEBHOOK_URL" ]]; then
    curl -fsS --max-time 5 -H 'Content-Type: application/json' \
      -d "{\"content\":\"🚨 SombraViva $(hostname): [$nivel] $categoria $msg\"}" \
      "$ALERTA_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# Classifica um valor inteiro em INFO/WARN/CRIT
classificar() {
  local valor="$1" warn="$2" crit="$3"
  if ((valor >= crit)); then echo CRIT
  elif ((valor >= warn)); then echo WARN
  else echo INFO
  fi
}

# --------------------------------------------------------------- CPU ---------
# Uso de CPU = 1 - (delta idle / delta total) entre duas leituras de /proc/stat
uso_cpu() {
  local a b
  read -r -a a < <(grep '^cpu ' /proc/stat)
  sleep 1
  read -r -a b < <(grep '^cpu ' /proc/stat)
  local total_a=0 total_b=0 i
  for i in 1 2 3 4 5 6 7 8; do
    total_a=$((total_a + ${a[i]:-0}))
    total_b=$((total_b + ${b[i]:-0}))
  done
  local idle_a=$(( a[4] + a[5] )) idle_b=$(( b[4] + b[5] ))
  local dt=$((total_b - total_a)) di=$((idle_b - idle_a))
  ((dt > 0)) || { echo 0; return; }
  echo $(( (100 * (dt - di)) / dt ))
}

verificar_cpu() {
  local uso nivel carga
  uso="$(uso_cpu)"
  carga="$(cut -d' ' -f1-3 /proc/loadavg)"
  nivel="$(classificar "$uso" "$CPU_WARN" "$CPU_CRIT")"
  alerta "$nivel" "CPU" "uso=${uso}% (warn ${CPU_WARN}% / crit ${CPU_CRIT}%) load=${carga} nucleos=$(nproc)"
}

# ------------------------------------------------------------ memória --------
verificar_memoria() {
  local total disp uso nivel
  total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  disp="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  uso=$(( (100 * (total - disp)) / total ))
  nivel="$(classificar "$uso" "$MEM_WARN" "$MEM_CRIT")"
  alerta "$nivel" "MEMORIA" "uso=${uso}% livre=$((disp / 1024))MB total=$((total / 1024))MB (warn ${MEM_WARN}% / crit ${MEM_CRIT}%)"
}

# --------------------------------------------------------------- disco -------
verificar_disco() {
  local ponto uso livre nivel
  for ponto in $DISCO_PONTOS; do
    if ! df -P "$ponto" >/dev/null 2>&1; then
      alerta WARN "DISCO" "ponto de montagem ${ponto} não encontrado"
      continue
    fi
    uso="$(df -P "$ponto" | awk 'NR==2 {gsub("%","",$5); print $5}')"
    livre="$(df -Ph "$ponto" | awk 'NR==2 {print $4}')"
    nivel="$(classificar "$uso" "$DISCO_WARN" "$DISCO_CRIT")"
    alerta "$nivel" "DISCO" "${ponto} uso=${uso}% livre=${livre} (warn ${DISCO_WARN}% / crit ${DISCO_CRIT}%)"
  done
}

# ------------------------------------------------------------ aplicação ------
verificar_api() {
  if ! command -v curl >/dev/null 2>&1; then
    alerta WARN "API" "curl não instalado — health check ignorado"
    return
  fi
  local corpo codigo tempo
  corpo="$(mktemp)"
  local saida
  saida="$(curl -s -o "$corpo" -w '%{http_code} %{time_total}' \
             --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null || true)"
  codigo="${saida%% *}"; tempo="${saida##* }"
  [[ "$codigo" =~ ^[0-9]{3}$ ]] || codigo="000"
  case "$codigo" in
    200) alerta INFO "API" "health OK (HTTP 200 em ${tempo}s) $HEALTH_URL" ;;
    503) alerta CRIT "API" "API no ar mas BANCO indisponível (HTTP 503): $(tr -d '\n' <"$corpo" | cut -c1-160)" ;;
    000) alerta CRIT "API" "API NÃO responde em $HEALTH_URL (timeout/conexão recusada)" ;;
    *)   alerta WARN "API" "resposta inesperada HTTP $codigo de $HEALTH_URL" ;;
  esac
  rm -f "$corpo"
}

verificar_servicos() {
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    alerta INFO "SERVICO" "systemd indisponível neste ambiente — verificação de serviços ignorada"
    return
  fi
  local svc estado
  for svc in $SERVICOS; do
    estado="$(systemctl is-active "$svc" 2>/dev/null || true)"
    case "$estado" in
      active) alerta INFO "SERVICO" "${svc} ativo" ;;
      activating|reloading) alerta WARN "SERVICO" "${svc} em transição (${estado})" ;;
      *) alerta CRIT "SERVICO" "${svc} INATIVO (estado: ${estado:-desconhecido})" ;;
    esac
  done
  # MySQL respondendo de fato (não só o processo de pé)
  if command -v mysqladmin >/dev/null 2>&1 && [[ " $SERVICOS " == *" mysql "* ]]; then
    if mysqladmin ping --silent >/dev/null 2>&1; then
      alerta INFO "MYSQL" "mysqladmin ping OK"
    else
      alerta CRIT "MYSQL" "MySQL não responde ao ping"
    fi
  fi
}

ciclo() {
  PIOR=0
  verificar_cpu
  verificar_memoria
  verificar_disco
  verificar_api
  verificar_servicos
  local resumo="OK"
  ((PIOR == 1)) && resumo="ATENCAO"
  ((PIOR == 2)) && resumo="CRITICO"
  printf '%s [----] RESUMO   ciclo concluído: %s\n' "$(_sv_ts)" "$resumo" >>"$MONITOR_LOG" 2>/dev/null || true
}

encerrar() {
  alerta INFO "MONITOR" "monitor encerrado (sinal recebido) pid=$$"
  exit 0
}

if [[ "$MODO" == "loop" ]]; then
  trap encerrar SIGTERM SIGINT
  alerta INFO "MONITOR" "iniciado em modo contínuo, intervalo=${INTERVALO}s, conf=${CONF}, pid=$$"
  while true; do
    ciclo || alerta WARN "MONITOR" "erro inesperado no ciclo (seguindo)"
    # 'sleep &' + 'wait' permite responder ao SIGTERM imediatamente
    sleep "$INTERVALO" &
    wait $! || true
  done
else
  ciclo
  exit 0
fi
