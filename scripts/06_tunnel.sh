#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 06_tunnel.sh  (opcional)
#  Cria uma URL pública HTTPS temporária para a API usando o Cloudflare
#  Quick Tunnel (cloudflared). Necessário para o ESP32 do Wokwi alcançar a
#  API da VM, porque o simulador roda na internet e não enxerga a sua rede.
#
#  Uso:  sudo ./scripts/06_tunnel.sh        (Ctrl+C encerra o túnel)
#  Depois copie a URL mostrada para API_URL no sketch.ino:
#        const char* API_URL = "https://XXXX.trycloudflare.com/api/v1/medicoes";
#
#  Obs.: a URL muda a cada execução e não precisa de conta na Cloudflare.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "06_tunnel" "$@"
log_banner "06 · Túnel público (Cloudflare Quick Tunnel)"

ALVO="${ALVO:-http://localhost:80}"
SAIDA="$LOG_DIR/cloudflared.out"
PID_TUNEL=""

sv_cleanup() {
  [[ -n "$PID_TUNEL" ]] && kill "$PID_TUNEL" 2>/dev/null || true
}

instalar_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log_ok "cloudflared já instalado ($(cloudflared --version 2>&1 | head -n1))"
    return
  fi
  local arq deb
  case "$(dpkg --print-architecture)" in
    amd64) arq="amd64" ;;
    arm64) arq="arm64" ;;
    *) die "Arquitetura não suportada: $(dpkg --print-architecture)" ;;
  esac
  deb="$(mktemp --suffix=.deb)"
  log_info "Baixando cloudflared ($arq) do GitHub oficial da Cloudflare…"
  run curl -fsSL -o "$deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arq}.deb"
  run dpkg -i "$deb"
  rm -f "$deb"
  audit "PACOTE_INSTALADO cloudflared"
  log_ok "cloudflared instalado"
}

main() {
  instalar_cloudflared
  curl -fsS --max-time 3 "$ALVO/health" >/dev/null || log_warn "A API não respondeu em $ALVO/health — rode o provision.sh antes"
  log_info "Abrindo túnel para $ALVO…"
  : >"$SAIDA"
  cloudflared tunnel --no-autoupdate --url "$ALVO" >>"$SAIDA" 2>&1 &
  PID_TUNEL=$!
  local url=""
  for _ in $(seq 1 40); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$SAIDA" | head -n1 || true)"
    [[ -n "$url" ]] && break
    sleep 1
  done
  [[ -n "$url" ]] || { tail -n 20 "$SAIDA" >&2; die "Não foi possível obter a URL do túnel"; }
  audit "TUNEL_ABERTO url=$url alvo=$ALVO"
  printf '\n%s%s  URL pública: %s%s\n' "$C_NEGRITO" "$C_VERDE" "$url" "$C_RESET" >&2
  printf '  Dashboard:  %s/\n  Swagger:    %s/docs\n' "$url" "$url" >&2
  printf '\n  No sketch.ino (Wokwi) use:\n  %sconst char* API_URL = "%s/api/v1/medicoes";%s\n\n' "$C_AMARELO" "$url" "$C_RESET" >&2
  printf '  Teste rápido: ./scripts/simular_esp32.sh -u %s\n\n' "$url" >&2
  log_info "Túnel ativo (PID $PID_TUNEL). Ctrl+C para encerrar. Saída: $SAIDA"
  wait "$PID_TUNEL" || true
}

main
