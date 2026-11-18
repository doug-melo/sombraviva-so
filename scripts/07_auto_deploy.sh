#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 07_auto_deploy.sh
#  Deploy contínuo por "pull": a VM verifica sozinha se há código novo e reimplanta.
# -----------------------------------------------------------------------------
#  Fontes observadas:
#   - este repositório (sombraviva-so): scripts, configuração e os patches da API
#   - a branch da API de SOA definida em config/app.conf (APP_GIT_URL / APP_GIT_BRANCH)
#  Quando qualquer uma muda:
#   1. trava com flock (nunca dois deploys ao mesmo tempo)
#   2. atualiza este repositório com fast-forward (não apaga edições locais)
#   3. roda o 02_provision_app.sh, que reaplica os patches, migra o banco,
#      reinicia a API e faz o health check
#   4. se falhar, volta este repositório para o commit anterior e reimplanta
#   5. grava o commit implantado em /var/lib/sombraviva/deploy.state
#
#  Uso:
#   sudo ./scripts/07_auto_deploy.sh --install   instala e liga o timer (a cada 2 min)
#   sudo ./scripts/07_auto_deploy.sh             verifica agora e implanta se houver novidade
#   sudo ./scripts/07_auto_deploy.sh --force     reimplanta mesmo sem novidade
#   sudo ./scripts/07_auto_deploy.sh --status    mostra o último deploy e o timer
#   sudo ./scripts/07_auto_deploy.sh --uninstall desliga o timer
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "07_auto_deploy" "$@"

APP_GIT_URL="https://github.com/JoaoKraideM/Global-Solution---2-semestre---Cyber-Soa.git"
APP_GIT_BRANCH="main"
DEPLOY_BRANCH="main"
load_conf "${APP_CONF:-$REPO_DIR/config/app.conf}"

ESTADO_DIR="/var/lib/sombraviva"
ESTADO="$ESTADO_DIR/deploy.state"
TRAVA="/run/sombraviva-deploy.lock"
UNIT_DIR="/etc/systemd/system"
DONO="$(stat -c %U "$REPO_DIR")"

# git sempre como o dono do clone: evita o erro "dubious ownership" e arquivos de root no repositório
g() { runuser -u "$DONO" -- git -C "$REPO_DIR" "$@"; }

ler_estado() { [[ -f "$ESTADO" ]] && grep -E "^$1=" "$ESTADO" | cut -d= -f2- || true; }

gravar_estado() {
  install -d -m 755 "$ESTADO_DIR"
  {
    echo "SO_COMMIT=$1"
    echo "API_COMMIT=$2"
    echo "QUANDO=$(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "RESULTADO=$3"
  } >"$ESTADO"
}

instalar() {
  log_banner "07 · Instalando o deploy automático"
  local unit
  for unit in sombraviva-deploy.service sombraviva-deploy.timer; do
    sed "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/systemd/$unit" >"$UNIT_DIR/$unit"
    chmod 644 "$UNIT_DIR/$unit"
  done
  run systemctl daemon-reload
  run systemctl enable --now sombraviva-deploy.timer
  audit "AUTO_DEPLOY instalado repo=$REPO_DIR branch=$DEPLOY_BRANCH"
  log_ok "Timer ligado: verifica $REPO_DIR ($DEPLOY_BRANCH) e $APP_GIT_URL ($APP_GIT_BRANCH) a cada 2 minutos"
  systemctl list-timers sombraviva-deploy.timer --no-pager >&2 || true
}

desinstalar() {
  systemctl disable --now sombraviva-deploy.timer >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/sombraviva-deploy.service" "$UNIT_DIR/sombraviva-deploy.timer"
  systemctl daemon-reload
  audit "AUTO_DEPLOY removido"
  log_ok "Deploy automático desligado"
}

mostrar_status() {
  log_banner "07 · Situação do deploy automático"
  if [[ -f "$ESTADO" ]]; then
    sed 's/^/   /' "$ESTADO" >&2
  else
    log_warn "Nenhum deploy automático registrado ainda"
  fi
  systemctl list-timers sombraviva-deploy.timer --no-pager >&2 || true
  log_info "Histórico: journalctl -t sombraviva-audit | grep DEPLOY   ·   log: $LOG_FILE"
}

implantar() {
  # 02 é idempotente: reaplica patches sobre a main da API, migra, reinicia e testa /health
  "$SCRIPT_DIR/02_provision_app.sh"
}

verificar_e_implantar() {
  local forcar="$1"
  exec 9>"$TRAVA"
  if ! flock -n 9; then
    log_warn "Outro deploy está em andamento; esta verificação foi pulada"
    return 0
  fi

  run g fetch --quiet origin "$DEPLOY_BRANCH"
  local so_atual so_remoto api_remoto so_impl api_impl
  so_atual="$(g rev-parse HEAD)"
  so_remoto="$(g rev-parse "origin/$DEPLOY_BRANCH")"
  api_remoto="$(git ls-remote "$APP_GIT_URL" "refs/heads/$APP_GIT_BRANCH" | cut -f1)"
  [[ -n "$api_remoto" ]] || die "Não consegui ler $APP_GIT_BRANCH de $APP_GIT_URL (rede ou URL)"
  so_impl="$(ler_estado SO_COMMIT)"
  api_impl="$(ler_estado API_COMMIT)"

  if [[ "$forcar" != "sim" && "$so_remoto" == "$so_impl" && "$api_remoto" == "$api_impl" ]]; then
    log_info "Sem novidades (sombraviva-so ${so_remoto:0:7}, API ${api_remoto:0:7})"
    return 0
  fi

  log_banner "07 · Novo deploy"
  log_info "sombraviva-so: ${so_impl:0:7} -> ${so_remoto:0:7}"
  log_info "API de SOA:    ${api_impl:0:7} -> ${api_remoto:0:7}"
  audit "DEPLOY_INICIO so=${so_remoto:0:12} api=${api_remoto:0:12}"

  if [[ "$so_atual" != "$so_remoto" ]]; then
    if ! run g merge --ff-only "origin/$DEPLOY_BRANCH"; then
      gravar_estado "$so_impl" "$api_impl" "falha: o clone na VM tem mudanças locais que impedem o fast-forward"
      die "O clone em $REPO_DIR tem commits ou edições locais. Resolva com git status antes do próximo deploy."
    fi
  fi

  if implantar; then
    gravar_estado "$so_remoto" "$api_remoto" "sucesso"
    audit "DEPLOY_OK so=${so_remoto:0:12} api=${api_remoto:0:12}"
    log_ok "Deploy concluído: sombraviva-so ${so_remoto:0:7}, API ${api_remoto:0:7}"
    return 0
  fi

  log_error "O deploy falhou. Voltando o sombraviva-so para ${so_atual:0:7} e reimplantando."
  audit "DEPLOY_FALHA so=${so_remoto:0:12} api=${api_remoto:0:12} rollback=${so_atual:0:12}"
  run g reset --hard "$so_atual"
  if implantar; then
    # Guarda o commit remoto como visto para não repetir a mesma falha a cada 2 minutos
    gravar_estado "$so_remoto" "$api_remoto" "falha; rollback para ${so_atual:0:7} no ar"
    log_warn "Rollback concluído: a versão anterior está no ar"
  else
    gravar_estado "$so_remoto" "$api_remoto" "falha; rollback também falhou"
    die "O rollback também falhou. Veja $LOG_FILE e /var/log/sombraviva/02_provision_app.log"
  fi
  return 1
}

case "${1:-}" in
  --install)   instalar ;;
  --uninstall) desinstalar ;;
  --status)    mostrar_status ;;
  --force)     verificar_e_implantar sim ;;
  "")          verificar_e_implantar nao ;;
  *)           die "Opção desconhecida: $1 (use --install, --status, --force ou --uninstall)" ;;
esac
