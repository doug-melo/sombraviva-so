#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 04_setup_monitoring.sh
#  Rubricas: "Monitoramento como serviço systemd tolerante a falhas" (1 pt)
#            "Logs de auditoria e de execução" (1 pt)
# -----------------------------------------------------------------------------
#  O que faz (idempotente):
#   1. Instala 03_monitor.sh + lib/ em /opt/sombraviva/scripts e o
#      monitor.conf em /etc/sombraviva/
#   2. Instala e habilita sombraviva-monitor.service (Restart=always,
#      StartLimit) + timer guardião sombraviva-monitor-guard.timer
#   3. Auditoria: regras do auditd (/etc/audit/rules.d/sombraviva.rules)
#   4. Rotação de logs: /etc/logrotate.d/sombraviva
#   5. Mostra as evidências (status do serviço e últimas linhas do log)
#
#  Uso:  sudo ./scripts/04_setup_monitoring.sh
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "04_setup_monitoring" "$@"
log_banner "04 · Monitoramento (systemd) e auditoria"

APP_DIR="/opt/sombraviva"
DEST_SCRIPTS="$APP_DIR/scripts"
UNIT_DIR="/etc/systemd/system"

# ------------------------------------------------------------------ 1 --------
instalar_scripts() {
  log_step "1/5 Instalando o script de monitoramento"
  install -d -m 755 "$DEST_SCRIPTS" "$DEST_SCRIPTS/lib"
  install -m 755 "$SCRIPT_DIR/03_monitor.sh" "$DEST_SCRIPTS/03_monitor.sh"
  install -m 644 "$SCRIPT_DIR/lib/log.sh" "$DEST_SCRIPTS/lib/log.sh"
  install -d -m 750 -o root -g "$(id -gn sombraviva 2>/dev/null || echo root)" /etc/sombraviva
  if [[ -f /etc/sombraviva/monitor.conf ]] && cmp -s "$REPO_DIR/config/monitor.conf" /etc/sombraviva/monitor.conf; then
    log_ok "monitor.conf já atualizado"
  else
    install -m 640 "$REPO_DIR/config/monitor.conf" /etc/sombraviva/monitor.conf
    audit "MONITOR_CONF_ATUALIZADO /etc/sombraviva/monitor.conf"
    log_ok "Limites instalados em /etc/sombraviva/monitor.conf"
  fi
  install -d -m 750 -o root -g adm "$LOG_DIR"
  log_ok "Scripts em $DEST_SCRIPTS"
}

# ------------------------------------------------------------------ 2 --------
instalar_servico() {
  log_step "2/5 Serviço systemd sombraviva-monitor + timer guardião"
  local unit mudou=0
  for unit in sombraviva-monitor.service sombraviva-monitor-guard.service sombraviva-monitor-guard.timer; do
    if ! cmp -s "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"; then
      install -m 644 "$REPO_DIR/systemd/$unit" "$UNIT_DIR/$unit"
      mudou=1
      audit "SYSTEMD_UNIT_ATUALIZADA $UNIT_DIR/$unit"
    fi
  done
  systemd-analyze verify "$UNIT_DIR/sombraviva-monitor.service" >>"$LOG_FILE" 2>&1 || log_warn "systemd-analyze apontou avisos (ver $LOG_FILE)"
  ((mudou)) && run systemctl daemon-reload
  run systemctl enable sombraviva-monitor.service sombraviva-monitor-guard.timer
  run systemctl restart sombraviva-monitor.service
  run systemctl start sombraviva-monitor-guard.timer
  sleep 3
  if systemctl is-active --quiet sombraviva-monitor.service; then
    log_ok "sombraviva-monitor ATIVO (PID $(systemctl show -p MainPID --value sombraviva-monitor.service))"
  else
    systemctl --no-pager status sombraviva-monitor.service >&2 || true
    die "sombraviva-monitor não subiu"
  fi
  log_info "Política de reinício: $(systemctl show -p Restart,RestartUSec sombraviva-monitor.service | paste -sd' ')"
}

# ------------------------------------------------------------------ 3 --------
configurar_auditd() {
  log_step "3/5 Auditoria do sistema (auditd)"
  if ! dpkg -s auditd >/dev/null 2>&1; then
    run apt-get update -qq
    run apt-get install -y -qq auditd || { log_warn "auditd não pôde ser instalado — seguindo só com os logs dos scripts"; return 0; }
  fi
  install -d -m 750 /etc/audit/rules.d
  local regras="/etc/audit/rules.d/sombraviva.rules" tmp
  tmp="$(mktemp)"
  cat "$REPO_DIR/auditd/sombraviva.rules" >"$tmp"
  # Também vigia a pasta de scripts do repositório clonado
  printf '\n## Repositório clonado (gerado pelo 04_setup_monitoring.sh)\n-w %s/scripts/ -p wa -k sombraviva_repo\n' "$REPO_DIR" >>"$tmp"
  if ! cmp -s "$tmp" "$regras"; then
    install -m 640 "$tmp" "$regras"
    audit "AUDITD_REGRAS_ATUALIZADAS $regras"
  fi
  rm -f "$tmp"
  run systemctl enable --now auditd || true
  if command -v augenrules >/dev/null 2>&1 && run augenrules --load; then
    log_ok "Regras do auditd carregadas: $(auditctl -l 2>/dev/null | grep -c sombraviva || echo 0) regras 'sombraviva'"
  else
    log_warn "Não foi possível carregar as regras no kernel (comum em containers). Arquivo: $regras"
  fi
}

# ------------------------------------------------------------------ 4 --------
configurar_logrotate() {
  log_step "4/5 Rotação de logs (logrotate)"
  dpkg -s logrotate >/dev/null 2>&1 || run apt-get install -y -qq logrotate
  install -m 644 "$REPO_DIR/logrotate/sombraviva" /etc/logrotate.d/sombraviva
  if run logrotate -d /etc/logrotate.d/sombraviva; then
    log_ok "logrotate configurado: diário, 14 cópias, compactado"
  else
    log_warn "logrotate -d retornou aviso (ver $LOG_FILE)"
  fi
}

# ------------------------------------------------------------------ 5 --------
mostrar_evidencias() {
  log_step "5/5 Evidências"
  systemctl --no-pager --lines=0 status sombraviva-monitor.service >&2 || true
  log_info "Últimas linhas de $LOG_DIR/monitor.log:"
  tail -n 8 "$LOG_DIR/monitor.log" 2>/dev/null | sed 's/^/      /' >&2 || true
  log_info "Acompanhar ao vivo:  sudo tail -f $LOG_DIR/monitor.log"
  log_info "Alertas no syslog:   journalctl -t sombraviva-monitor -p warning"
  log_info "Auditoria:           sudo tail $LOG_DIR/auditoria.log  |  journalctl -t sombraviva-audit"
}

main() {
  instalar_scripts
  instalar_servico
  configurar_auditd
  configurar_logrotate
  mostrar_evidencias
  log_ok "Monitoramento e auditoria configurados. Log: $LOG_FILE"
}

main "$@"
