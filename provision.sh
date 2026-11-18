#!/usr/bin/env bash
# =============================================================================
#  🌳 SombraViva — provision.sh
#  Provisionamento COMPLETO da VM com um único comando:
#
#      sudo ./provision.sh
#
#  Ordem de execução:
#   01_provision_infra.sh    rede, DNS, IP, fuso, firewall, usuário
#   02_provision_app.sh      dependências, MySQL, API (systemd) e Nginx
#   04_setup_monitoring.sh   monitor (systemd) + auditoria + logrotate
#   (03_monitor.sh roda continuamente como serviço sombraviva-monitor)
#
#  Opções:
#   --sem-rede     pula o 01 (útil para reinstalar só a aplicação)
#   --simular      ao final envia medições de teste (simular_esp32.sh)
# =============================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
# shellcheck source=scripts/lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

SEM_REDE=0
SIMULAR=0
for arg in "$@"; do
  case "$arg" in
    --sem-rede) SEM_REDE=1 ;;
    --simular)  SIMULAR=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Opção inválida: $arg" ;;
  esac
done

require_root "$@"
log_init "provision" "$@"


printf '%s' "$C_VERDE" >&2
cat >&2 <<'ART'

   ____                  _               __     ___
  / ___|  ___  _ __ ___ | |__  _ __ __ _ \ \   / (_)_   ____ _
  \___ \ / _ \| '_ ` _ \| '_ \| '__/ _` | \ \ / /| \ \ / / _` |
   ___) | (_) | | | | | | |_) | | | (_| |  \ V / | |\ V / (_| |
  |____/ \___/|_| |_| |_|_.__/|_|  \__,_|   \_/  |_| \_/ \__,_|

        Inteligência Climática Urbana · Global Solution FIAP 2026
ART
printf '%s\n' "$C_RESET" >&2
log_info "Início do provisionamento: $(date '+%d/%m/%Y %H:%M:%S %Z') por ${SUDO_USER:-root}"

INICIO=$(date +%s)
chmod +x "$SCRIPT_DIR"/*.sh

executar() {
  local script="$1"
  local t0=$SECONDS
  log_step "Executando $script"
  # LOG_DIR é herdado para que todos escrevam no mesmo diretório
  LOG_DIR="$LOG_DIR" "$SCRIPT_DIR/$script"
  log_ok "$script concluído em $((SECONDS - t0))s"
}

if ((SEM_REDE)); then
  log_warn "--sem-rede: pulando 01_provision_infra.sh"
else
  executar 01_provision_infra.sh
fi
executar 02_provision_app.sh
executar 04_setup_monitoring.sh
if ((SIMULAR)); then
  "$SCRIPT_DIR/simular_esp32.sh" -n 3 -i 1 || log_warn "Simulação falhou"
fi

# ------------------------------------------------------------ resumo ---------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
estado() {
  local s
  s="$(systemctl is-active "$1" 2>/dev/null || true)"
  if [[ "$s" == "active" ]]; then printf '%s●%s %-28s %s\n' "$C_VERDE" "$C_RESET" "$1" "$s"
  else printf '%s●%s %-28s %s\n' "$C_VERMELHO" "$C_RESET" "$1" "${s:-desconhecido}"; fi
}

{
  printf '\n%s%s==================== RESUMO DO PROVISIONAMENTO ====================%s\n' "$C_NEGRITO" "$C_VERDE" "$C_RESET"
  printf '  Servidor:   %s (%s)   Tempo total: %ss\n' "$(hostname)" "${IP:-?}" "$(( $(date +%s) - INICIO ))"
  printf '\n  %sAcesse:%s\n' "$C_NEGRITO" "$C_RESET"
  printf '   Dashboard:  http://%s/   ou   http://sombraviva.local/ (dentro da VM)\n' "${IP:-IP-DA-VM}"
  printf '   Swagger:    http://%s/docs\n' "${IP:-IP-DA-VM}"
  printf '   Health:     http://%s/health   |   API direta: http://%s:8000/health\n' "${IP:-IP-DA-VM}" "${IP:-IP-DA-VM}"
  printf '   ESP32:      POST http://%s/api/v1/medicoes  (público: sudo ./scripts/06_tunnel.sh)\n' "${IP:-IP-DA-VM}"
  printf '\n  %sServiços:%s\n' "$C_NEGRITO" "$C_RESET"
  for svc in sombraviva-api nginx mysql sombraviva-monitor sombraviva-monitor-guard.timer auditd ufw; do
    printf '   '; estado "$svc"
  done
  printf '\n  %sHealth check:%s %s\n' "$C_NEGRITO" "$C_RESET" "$(curl -s --max-time 3 http://127.0.0.1/health || echo 'sem resposta')"
  printf '\n  %sLogs e evidências:%s %s/\n' "$C_NEGRITO" "$C_RESET" "$LOG_DIR"
  find "$LOG_DIR" -maxdepth 1 -type f -printf '     - %f\n' 2>/dev/null | sort
  printf '\n  Próximos passos: sudo tail -f %s/monitor.log  |  sudo ./scripts/05_teste_falha.sh\n' "$LOG_DIR"
  printf '%s%s==================================================================%s\n\n' "$C_NEGRITO" "$C_VERDE" "$C_RESET"
} >&2
log_ok "Provisionamento concluído!"
