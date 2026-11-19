#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 08_coletar_evidencias.sh
#  Junta num único arquivo as evidências de texto e os logs da VM para a
#  entrega (pasta evidencias/logs/ do repositório).
# -----------------------------------------------------------------------------
#  Uso:
#   sudo ./scripts/08_coletar_evidencias.sh
#
#  Gera ~/evidencias_sombraviva.tar.gz (no home de quem rodou o sudo) com:
#   01_sistema.txt ... 10_auto_deploy.txt   saída dos comandos de verificação
#   logs/*.log                              últimas linhas de /var/log/sombraviva
#
#  Tokens, senhas e cabeçalhos Bearer são mascarados antes de copiar.
#  Nada é alterado na VM: o script só lê.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "08_coletar_evidencias" "$@"
log_banner "08 · Coleta de evidências"

DONO="${SUDO_USER:-root}"
HOME_DONO="$(getent passwd "$DONO" | cut -d: -f6)"
DESTINO="$(mktemp -d /tmp/sombraviva_evidencias.XXXXXX)"
SAIDA="$HOME_DONO/evidencias_sombraviva.tar.gz"
LINHAS_LOG="${LINHAS_LOG:-2000}"
sv_cleanup() { rm -rf "$DESTINO"; }   # chamado pelo trap EXIT do log.sh

# Mascara segredos: Bearer, variáveis *TOKEN*/*SENHA*/*PASSWORD*/*SECRET*/*KEY*
mascarar() {
  sed -E \
    -e 's/(Bearer )[A-Za-z0-9._~+\/=-]+/\1***OCULTO***/g' \
    -e 's/(([A-Za-z_]*(TOKEN|SENHA|PASSWORD|SECRET|KEY)[A-Za-z_]*)"?[=:] *"?)[^" ,}]+/\1***OCULTO***/Ig' \
    -e 's/(sv-dev-)[A-Za-z0-9_-]+/\1***OCULTO***/g'
}

# Roda cada comando, grava "$ comando" + saída no arquivo e segue mesmo se falhar
secao() {
  local arquivo="$DESTINO/$1"; shift
  local cmd
  for cmd in "$@"; do
    {
      printf '$ %s\n' "$cmd"
      bash -c "$cmd" 2>&1 || printf '(comando terminou com erro %s)\n' "$?"
      printf '\n'
    } | mascarar >> "$arquivo"
  done
  log_ok "$(basename "$arquivo")"
}

{
  printf 'SombraViva — evidências coletadas em %s\n' "$(date '+%d/%m/%Y %H:%M:%S %z')"
  printf 'Host: %s | Usuário: %s | Commit do repositório: %s\n' \
    "$(hostname)" "$DONO" "$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
} > "$DESTINO/00_LEIAME.txt"

secao 01_sistema.txt \
  "hostnamectl" "uname -a" "cat /etc/os-release" "uptime" "nproc" "free -h" "df -h /"

secao 02_rede_dns.txt \
  "ip -br a" "ip route" "cat /etc/hosts" \
  "getent hosts sombraviva.local" "resolvectl status | head -30" \
  "getent hosts api.open-meteo.com"

secao 03_firewall.txt \
  "ufw status verbose" "ss -tlnp | grep -E ':(22|80|8000|3306) '"

secao 04_servicos.txt \
  "systemctl is-enabled sombraviva-api sombraviva-monitor nginx mysql auditd" \
  "systemctl status sombraviva-api sombraviva-monitor nginx mysql --no-pager -n 5" \
  "systemctl list-timers 'sombraviva*' --no-pager" \
  "systemctl show sombraviva-api sombraviva-monitor -p Restart -p RestartUSec -p NRestarts"

secao 05_usuarios_permissoes.txt \
  "getent passwd sombraviva" "id sombraviva" \
  "stat -c '%A %U:%G %n' /etc/sombraviva/sombraviva.env" \
  "ls -ld /opt/sombraviva /etc/sombraviva /var/log/sombraviva" \
  "ls -l /var/log/sombraviva"

secao 06_aplicacao_health.txt \
  "curl -s -i http://127.0.0.1/health" \
  "curl -s http://127.0.0.1/api/v1/resumo" \
  "curl -s -o /dev/null -w 'Swagger /docs -> HTTP %{http_code}\n' http://127.0.0.1/docs"

secao 07_journal_alertas.txt \
  "journalctl -t sombraviva-monitor -p warning --since today --no-pager" \
  "journalctl -t sombraviva-audit --since today --no-pager | tail -60"

secao 08_auditd.txt \
  "auditctl -l | grep -i sombraviva" \
  "ausearch -k sombraviva_config -i | tail -60"

secao 09_logrotate.txt \
  "cat /etc/logrotate.d/sombraviva" \
  "logrotate -d /etc/logrotate.d/sombraviva 2>&1 | tail -25"

secao 10_auto_deploy.txt \
  "bash $SCRIPT_DIR/07_auto_deploy.sh --status" \
  "tail -40 /var/log/sombraviva/07_auto_deploy.log"

# Cópia dos logs (só as últimas linhas, já mascaradas)
mkdir -p "$DESTINO/logs"
shopt -s nullglob
for arq in /var/log/sombraviva/*.log; do
  tail -n "$LINHAS_LOG" "$arq" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | mascarar > "$DESTINO/logs/$(basename "$arq")"
done
log_ok "logs copiados: $(find "$DESTINO/logs" -type f | wc -l) arquivo(s), até $LINHAS_LOG linhas cada"

tar -czf "$SAIDA" -C "$DESTINO" .
chown "$DONO": "$SAIDA"
log_ok "Arquivo pronto: $SAIDA ($(du -h "$SAIDA" | cut -f1))"
log_info "No seu computador: scp -i SUA_CHAVE $DONO@IP-PUBLICO:$SAIDA ."
