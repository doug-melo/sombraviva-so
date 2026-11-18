#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  SombraViva — biblioteca compartilhada de log e auditoria
# -----------------------------------------------------------------------------
#  Carregada por TODOS os scripts com:  source "$SCRIPT_DIR/lib/log.sh"
#
#  O que ela oferece:
#   * saída colorida no terminal (INFO/OK/WARN/ERRO/PASSO)
#   * cada script grava em /var/log/sombraviva/<script>.log com data/hora
#   * trilha de auditoria em /var/log/sombraviva/auditoria.log + syslog
#     (tag "sombraviva-audit"): QUEM executou (SUDO_USER), QUANDO, ONDE,
#     com quais argumentos, hash do script e código de saída
#   * tratamento de erro (trap ERR) mostrando a linha e o comando que falhou
#
#  Variáveis que podem ser sobrescritas:
#   LOG_DIR   diretório dos logs (padrão /var/log/sombraviva). Se não houver
#             permissão de escrita, cai para /tmp/sombraviva-logs (modo usuário)
#   NO_COLOR  se definida, desliga as cores
#   DEBUG=1   mostra no terminal os comandos executados por run()
# =============================================================================

# Evita carregar duas vezes
[[ -n "${_SV_LOG_CARREGADO:-}" ]] && return 0
_SV_LOG_CARREGADO=1

LOG_DIR="${LOG_DIR:-/var/log/sombraviva}"
LOG_FILE=""
AUDIT_FILE=""
SCRIPT_NOME="${SCRIPT_NOME:-sombraviva}"

# ---------------------------------------------------------------- cores ------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m'; C_NEGRITO=$'\e[1m'; C_VERMELHO=$'\e[31m'; C_VERDE=$'\e[32m'
  C_AMARELO=$'\e[33m'; C_AZUL=$'\e[34m'; C_CIANO=$'\e[36m'; C_CINZA=$'\e[90m'
else
  C_RESET=""; C_NEGRITO=""; C_VERMELHO=""; C_VERDE=""; C_AMARELO=""; C_AZUL=""
  C_CIANO=""; C_CINZA=""
fi
export C_RESET C_NEGRITO C_VERMELHO C_VERDE C_AMARELO C_AZUL C_CIANO C_CINZA

# Data/hora com fuso (ex.: 2026-11-17 14:30:00 -0300)
_sv_ts() { date '+%Y-%m-%d %H:%M:%S %z'; }

# Escreve no terminal (stderr, para não poluir capturas $(...)) e no arquivo
_sv_escrever() {
  local nivel="$1" cor="$2"; shift 2
  local msg="$*" ts
  ts="$(_sv_ts)"
  printf '%s%s [%-5s]%s %s\n' "$cor" "$ts" "$nivel" "$C_RESET" "$msg" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [%-5s] %s\n' "$ts" "$nivel" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

log_info()  { _sv_escrever "INFO" "$C_AZUL" "$*"; }
log_ok()    { _sv_escrever "OK" "$C_VERDE" "✔ $*"; }
log_warn()  { _sv_escrever "WARN" "$C_AMARELO" "⚠ $*"; }
log_error() { _sv_escrever "ERRO" "$C_VERMELHO" "✖ $*"; }
log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    _sv_escrever "DEBUG" "$C_CINZA" "$*"
  elif [[ -n "$LOG_FILE" ]]; then
    printf '%s [DEBUG] %s\n' "$(_sv_ts)" "$*" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

# Cabeçalho de etapa
log_step() {
  local msg="$*"
  printf '\n%s%s==> %s%s\n' "$C_NEGRITO" "$C_CIANO" "$msg" "$C_RESET" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s [PASSO] ==> %s\n' "$(_sv_ts)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

# Banner grande (início dos scripts)
log_banner() {
  local titulo="$*"
  printf '%s%s\n' "$C_VERDE" "==============================================================" >&2
  printf '  🌳 SombraViva | %s\n' "$titulo" >&2
  printf '%s%s\n' "==============================================================" "$C_RESET" >&2
}

die() {
  log_error "$*"
  exit 1
}

# --------------------------------------------------------- auditoria ---------
# Registra uma linha de auditoria no arquivo e no syslog (journalctl -t sombraviva-audit)
audit() {
  local quem linha
  quem="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo desconhecido)}}"
  linha="usuario=${quem} uid_efetivo=$(id -u) host=$(hostname 2>/dev/null || echo '?') script=${SCRIPT_NOME} pid=$$ $*"
  if [[ -n "$AUDIT_FILE" ]]; then
    printf '%s %s\n' "$(_sv_ts)" "$linha" >>"$AUDIT_FILE" 2>/dev/null || true
  fi
  if command -v logger >/dev/null 2>&1; then
    logger -t sombraviva-audit -- "$linha" 2>/dev/null || true
  fi
}

# --------------------------------------------------------- utilidades --------
# Executa um comando mandando a saída completa para o log do script.
# Uso: run apt-get install -y nginx
run() {
  log_debug "\$ $*"
  if ! "$@" >>"${LOG_FILE:-/dev/null}" 2>&1; then
    log_error "Comando falhou: $*"
    if [[ -n "$LOG_FILE" ]]; then
      log_error "Últimas linhas de $LOG_FILE:"
      tail -n 15 "$LOG_FILE" >&2 || true
    fi
    return 1
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Este script precisa de root. Execute: sudo $0 $*"
  fi
}

# Carrega um arquivo .conf (formato VAR=valor) se existir
load_conf() {
  local arquivo="$1"
  if [[ -f "$arquivo" ]]; then
    # shellcheck source=/dev/null
    source "$arquivo"
    log_debug "Configuração carregada: $arquivo"
  else
    log_warn "Arquivo de configuração não encontrado: $arquivo (usando padrões)"
  fi
}

# Escreve um arquivo apenas se o conteúdo mudou (idempotência).
# Uso: escrever_se_mudou /caminho/arquivo "$conteudo"  -> retorna 0 se mudou, 1 se igual
escrever_se_mudou() {
  local destino="$1" conteudo="$2"
  if [[ -f "$destino" ]] && [[ "$(cat "$destino")" == "$conteudo" ]]; then
    return 1
  fi
  mkdir -p "$(dirname "$destino")"
  printf '%s\n' "$conteudo" >"$destino"
  return 0
}

# -------------------------------------------------- tratamento de erros ------
_sv_on_err() {
  local codigo=$? linha="$1" comando="$2"
  log_error "Falha na linha ${linha}: '${comando}' (código ${codigo})"
}

_sv_on_exit() {
  local codigo=$?
  # Hook opcional: o script pode definir sv_cleanup() para limpar recursos
  if declare -F sv_cleanup >/dev/null; then
    sv_cleanup || true
  fi
  local duracao=$(( $(date +%s) - ${_SV_INICIO:-$(date +%s)} ))
  if [[ "$codigo" -eq 0 ]]; then
    audit "FIM status=sucesso codigo=0 duracao=${duracao}s"
  else
    audit "FIM status=falha codigo=${codigo} duracao=${duracao}s"
    log_error "Script terminou com erro (código ${codigo}). Log: ${LOG_FILE}"
  fi
}

# Inicializa log + auditoria. Uso: log_init "01_provision_infra" "$@"
log_init() {
  SCRIPT_NOME="$1"; shift || true
  if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    local alternativo="${TMPDIR:-/tmp}/sombraviva-logs"
    mkdir -p "$alternativo"
    printf '%s[WARN ] Sem permissão em %s — logs em %s (modo usuário)%s\n' \
      "$C_AMARELO" "$LOG_DIR" "$alternativo" "$C_RESET" >&2
    LOG_DIR="$alternativo"
  fi
  LOG_FILE="${LOG_DIR}/${SCRIPT_NOME}.log"
  AUDIT_FILE="${LOG_DIR}/auditoria.log"
  touch "$LOG_FILE" "$AUDIT_FILE" 2>/dev/null || true
  _SV_INICIO="$(date +%s)"

  local hash="?"
  if command -v sha256sum >/dev/null 2>&1 && [[ -f "$0" ]]; then
    hash="$(sha256sum "$0" | cut -c1-16)"
  fi
  {
    printf '\n%s\n' "------------------------------------------------------------------"
    printf '%s [INICIO] %s executado por %s (uid efetivo %s) em %s\n' \
      "$(_sv_ts)" "$SCRIPT_NOME" "${SUDO_USER:-${USER:-?}}" "$(id -u)" "$(hostname 2>/dev/null || echo '?')"
  } >>"$LOG_FILE" 2>/dev/null || true
  audit "INICIO caminho=$0 sha256=${hash} cwd=$(pwd) args='$*'"

  trap '_sv_on_err "$LINENO" "$BASH_COMMAND"' ERR
  trap '_sv_on_exit' EXIT
}
