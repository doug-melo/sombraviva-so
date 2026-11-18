#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 02_provision_app.sh
#  Rubrica: "Script de instalação de dependências e deploy da aplicação" (2 pts)
# -----------------------------------------------------------------------------
#  O que faz (idempotente):
#   1. Instala dependências: python3-venv, mysql-server, nginx, git, curl...
#   2. Cria o banco e o usuário MySQL (senha gerada ou vinda do app.conf)
#   3. Clona a API de SOA (repositório sombraviva-soa) para /opt/sombraviva/src e cria o venv
#   4. Gera /etc/sombraviva/sombraviva.env (chmod 600) com segredos aleatórios
#   5. Roda as migrações Alembic (alembic upgrade head) e o seed
#   6. Cria o serviço systemd sombraviva-api.service (Uvicorn, Restart=always)
#   7. Configura o Nginx como proxy reverso 80 -> 8000
#   8. Habilita/inicia tudo e faz o health check final com curl
#
#  Uso:  sudo ./scripts/02_provision_app.sh
#  Configuração: config/app.conf
# =============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "02_provision_app" "$@"
log_banner "02 · Dependências, MySQL, API, systemd e Nginx"

# ---------------------------------------------------------------- padrões ----
APP_DIR="/opt/sombraviva"
USUARIO_APP="sombraviva"
APP_ORIGEM="git"
APP_GIT_URL="https://github.com/doug-melo/sombraviva-soa.git"
APP_GIT_BRANCH="main"
APP_MODULO="app.main:app"
API_HOST="0.0.0.0"
API_PORTA="8000"
UVICORN_WORKERS="1"
DB_NAME="sombraviva"
DB_USER="sombraviva"
DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_PASSWORD=""
SOMBRAVIVA_DEVICE_TOKENS="esp32-osasco-calcadao-01:sv-dev-TROQUE-ESTE-TOKEN"
ADMIN_EMAIL="admin@sombraviva.local"
ADMIN_PASSWORD=""
OPENAI_MODEL="gpt-4.1-mini"
NGINX_SERVER_NAME="sombraviva.local _"
# APP_ORIGEM=local: pasta da API já clonada ao lado deste repositório
APP_FONTE="$(cd "$REPO_DIR/.." && pwd)/sombraviva-soa"
load_conf "${APP_CONF:-$REPO_DIR/config/app.conf}"

ENV_ARQ="/etc/sombraviva/sombraviva.env"
UNIT_ARQ="/etc/systemd/system/sombraviva-api.service"
NGINX_ARQ="/etc/nginx/sites-available/sombraviva"
PACOTES=(python3 python3-venv python3-pip mysql-server nginx git curl rsync ca-certificates openssl)

# ------------------------------------------------------------------ 1 --------
instalar_dependencias() {
  log_step "1/8 Dependências do sistema"
  local faltando=() pkg
  for pkg in "${PACOTES[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || faltando+=("$pkg")
  done
  if ((${#faltando[@]})); then
    log_info "Instalando: ${faltando[*]} (pode levar alguns minutos)"
    run apt-get update -qq
    run apt-get install -y -qq "${faltando[@]}"
    audit "PACOTES_INSTALADOS ${faltando[*]}"
  fi
  log_ok "Dependências OK: $(python3 --version 2>&1), $(mysql --version | awk '{print $1, $2, $3}'), $(nginx -v 2>&1 | cut -d/ -f2)"
  id "$USUARIO_APP" >/dev/null 2>&1 || \
    run useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$USUARIO_APP"
  install -d -m 750 -o root -g "$USUARIO_APP" /etc/sombraviva
  install -d -m 750 -o root -g adm "$LOG_DIR"
}

# ------------------------------------------------------------------ 2 --------
# Lê uma variável de um arquivo .env existente (para reutilizar a senha)
ler_env() {
  local chave="$1"
  [[ -f "$ENV_ARQ" ]] || return 0
  grep -E "^${chave}=" "$ENV_ARQ" | tail -n1 | cut -d= -f2- || true
}

configurar_mysql() {
  log_step "2/8 Banco de dados MySQL"
  run systemctl enable --now mysql
  # Espera o MySQL aceitar conexões
  for _ in $(seq 1 30); do
    mysqladmin ping --silent >/dev/null 2>&1 && break
    sleep 1
  done
  mysqladmin ping --silent >/dev/null 2>&1 || die "MySQL não respondeu em 30 s"

  # Senha: app.conf > senha já existente no .env > nova senha aleatória
  if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(ler_env DB_PASSWORD)"
    if [[ -z "$DB_PASSWORD" ]]; then
      DB_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
      log_info "Senha do banco gerada automaticamente (salva em $ENV_ARQ)"
    else
      log_info "Reutilizando a senha existente em $ENV_ARQ"
    fi
  fi
  [[ "$DB_PASSWORD" =~ ^[A-Za-z0-9@#%+=._-]+$ ]] || die "DB_PASSWORD contém caracteres não permitidos"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ && "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME/DB_USER inválidos"

  # No Ubuntu o root do MySQL autentica via socket (auth_socket) quando rodamos como root
  mysql --protocol=socket -uroot <<SQL >>"$LOG_FILE" 2>&1
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
  # Princípio do menor privilégio: o usuário só enxerga o próprio banco
  # MYSQL_PWD evita que a senha apareça na lista de processos (ps)
  if MYSQL_PWD="$DB_PASSWORD" mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -e "SELECT 1" "$DB_NAME" >/dev/null 2>&1; then
    log_ok "Banco '$DB_NAME' e usuário '$DB_USER' prontos (acesso testado)"
  else
    die "Usuário '$DB_USER' não conseguiu conectar no MySQL"
  fi
  audit "MYSQL banco=$DB_NAME usuario=$DB_USER"
}

# ------------------------------------------------------------------ 3 --------
implantar_codigo() {
  log_step "3/8 Código da API (SOA) e ambiente virtual Python"
  install -d -m 755 -o "$USUARIO_APP" -g "$USUARIO_APP" "$APP_DIR"
  if [[ "$APP_ORIGEM" == "git" ]]; then
    [[ -n "$APP_GIT_URL" ]] || die "APP_ORIGEM=git exige APP_GIT_URL em config/app.conf"
    if [[ -d "$APP_DIR/repo/.git" ]]; then
      run git -C "$APP_DIR/repo" fetch --depth 1 origin "$APP_GIT_BRANCH"
      run git -C "$APP_DIR/repo" reset --hard "origin/$APP_GIT_BRANCH"
    else
      rm -rf "$APP_DIR/repo"
      run git clone --depth 1 --branch "$APP_GIT_BRANCH" "$APP_GIT_URL" "$APP_DIR/repo"
    fi
    APP_FONTE="$APP_DIR/repo"
    log_ok "Código clonado de $APP_GIT_URL ($APP_GIT_BRANCH)"
  fi
  [[ -f "$APP_FONTE/app/main.py" && -f "$APP_FONTE/alembic.ini" ]] || die "API não encontrada em $APP_FONTE (esperado app/main.py e alembic.ini)"
  # Copia só o necessário para produção: sem testes, docs, .env ou caches
  run rsync -a --delete --exclude '__pycache__' --exclude '.env' --exclude 'tests/' --exclude 'docs/' \
      --exclude '.pytest_cache' --exclude '*.db' "$APP_FONTE/" "$APP_DIR/src/"
  log_ok "API copiada de $APP_FONTE para $APP_DIR/src"

  if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
    run python3 -m venv "$APP_DIR/venv"
    log_ok "venv criado em $APP_DIR/venv"
  fi
  log_info "Instalando pacotes Python (pip)…"
  run "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
  run "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/src/requirements.txt"
  chown -R "$USUARIO_APP:$USUARIO_APP" "$APP_DIR"
  log_ok "Pacotes Python instalados ($("$APP_DIR/venv/bin/pip" freeze | wc -l) pacotes)"
}

# ------------------------------------------------------------------ 4 --------
# Segredo: valor do app.conf > valor já salvo no .env > novo valor aleatório
segredo() {
  local chave="$1" atual="${2:-}"
  [[ -n "$atual" ]] && { printf '%s' "$atual"; return; }
  atual="$(ler_env "$chave")"
  [[ -n "$atual" ]] && { printf '%s' "$atual"; return; }
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

escrever_env() {
  log_step "4/8 Arquivo de ambiente ($ENV_ARQ)"
  local jwt admin_pw sensor_a sensor_b esp_id esp_token conteudo
  jwt="$(segredo JWT_SECRET)"
  admin_pw="$(segredo ADMIN_PASSWORD "$ADMIN_PASSWORD")"
  sensor_a="$(segredo SENSOR_A_KEY)"
  sensor_b="$(segredo SENSOR_B_KEY)"
  # SOMBRAVIVA_DEVICE_TOKENS = "device_id:token" (o mesmo do sketch.ino)
  esp_id="${SOMBRAVIVA_DEVICE_TOKENS%%:*}"
  esp_token="${SOMBRAVIVA_DEVICE_TOKENS#*:}"
  [[ -n "$esp_id" && -n "$esp_token" && "$esp_id" != "$esp_token" ]] || die "SOMBRAVIVA_DEVICE_TOKENS deve ter o formato device_id:token"
  conteudo="# SombraViva — gerado por 02_provision_app.sh. NÃO versionar (contém segredos).
APP_ENV=production
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
JWT_SECRET=${jwt}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${admin_pw}
SENSOR_A_KEY=${sensor_a}
SENSOR_B_KEY=${sensor_b}
ESP32_DEVICE_ID=${esp_id}
ESP32_DEVICE_TOKEN=${esp_token}
OPENAI_API_KEY=$(ler_env OPENAI_API_KEY)
OPENAI_MODEL=${OPENAI_MODEL}
PYTHONUNBUFFERED=1"
  if escrever_se_mudou "$ENV_ARQ" "$conteudo"; then
    audit "ENV_ATUALIZADO arquivo=$ENV_ARQ"
    log_ok "Arquivo de ambiente gravado"
  else
    log_ok "Arquivo de ambiente já atualizado"
  fi
  # 600 = só o root lê (o systemd lê como root e injeta no processo)
  chown root:root "$ENV_ARQ"
  chmod 600 "$ENV_ARQ"
  log_info "Permissões: $(stat -c '%A %U:%G %n' "$ENV_ARQ")"
}

# ------------------------------------------------------------------ 5 --------
migrar_e_popular() {
  log_step "5/8 Migrações Alembic e dados iniciais (seed)"
  # Subshell: carrega o .env sem vazar segredos para o resto do script
  (
    set -a
    # shellcheck disable=SC1090
    source "$ENV_ARQ"
    set +a
    cd "$APP_DIR/src"
    run "$APP_DIR/venv/bin/alembic" upgrade head
    log_ok "Esquema do MySQL na revisão: $("$APP_DIR/venv/bin/alembic" current 2>/dev/null | tail -n1)"
    run "$APP_DIR/venv/bin/python" -m app.seed
  )
  chown -R "$USUARIO_APP:$USUARIO_APP" "$APP_DIR"
  audit "ALEMBIC_UPGRADE_HEAD + SEED"
  log_ok "Banco migrado e populado (admin, estações, dispositivo ESP32)"
}

# ------------------------------------------------------------------ 6 --------
criar_servico() {
  log_step "6/8 Serviço systemd sombraviva-api"
  local modulo="$APP_MODULO" workdir="$APP_DIR/src"
  local conteudo
  conteudo="$(sed -e "s|@USUARIO_APP@|${USUARIO_APP}|g" \
                  -e "s|WorkingDirectory=@APP_DIR@|WorkingDirectory=${workdir}|" \
                  -e "s|@APP_DIR@|${APP_DIR}|g" \
                  -e "s|@APP_MODULO@|${modulo}|g" \
                  -e "s|@API_HOST@|${API_HOST}|g" \
                  -e "s|@API_PORTA@|${API_PORTA}|g" \
                  -e "s|@UVICORN_WORKERS@|${UVICORN_WORKERS}|g" \
                  "$REPO_DIR/systemd/sombraviva-api.service")"
  touch "$LOG_DIR/api.log"
  if escrever_se_mudou "$UNIT_ARQ" "$conteudo"; then
    run systemctl daemon-reload
    audit "SYSTEMD_UNIT_ATUALIZADA $UNIT_ARQ"
    log_ok "Unidade criada: $UNIT_ARQ"
  else
    log_ok "Unidade já atualizada"
  fi
  run systemctl enable sombraviva-api.service
  # restart garante que código/env novos sejam carregados
  run systemctl restart sombraviva-api.service
  log_ok "sombraviva-api: $(systemctl is-active sombraviva-api.service)"
}

# ------------------------------------------------------------------ 7 --------
configurar_nginx() {
  log_step "7/8 Nginx (proxy reverso 80 -> ${API_PORTA})"
  local conteudo
  conteudo="$(sed -e "s|@API_PORTA@|${API_PORTA}|g" -e "s|@NGINX_SERVER_NAME@|${NGINX_SERVER_NAME}|g" \
                  "$REPO_DIR/nginx/sombraviva.conf")"
  local mudou=0
  escrever_se_mudou "$NGINX_ARQ" "$conteudo" && mudou=1
  ln -sfn "$NGINX_ARQ" /etc/nginx/sites-enabled/sombraviva
  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    mudou=1
  fi
  run nginx -t
  run systemctl enable nginx
  if ((mudou)); then
    run systemctl reload-or-restart nginx
    audit "NGINX_ATUALIZADO $NGINX_ARQ"
  else
    run systemctl start nginx
  fi
  log_ok "Nginx: $(systemctl is-active nginx) — site 'sombraviva' habilitado"
}

# ------------------------------------------------------------------ 8 --------
health_check() {
  log_step "8/8 Health check final"
  local url_direta="http://127.0.0.1:${API_PORTA}/health" url_nginx="http://127.0.0.1/health" resposta
  for _ in $(seq 1 30); do
    if resposta="$(curl -fsS --max-time 3 "$url_nginx" 2>/dev/null)"; then
      log_ok "Via Nginx  ($url_nginx): $resposta"
      log_ok "Direto API ($url_direta): $(curl -fsS --max-time 3 "$url_direta")"
      audit "HEALTHCHECK ok"
      return 0
    fi
    sleep 2
  done
  log_error "A API não respondeu em 60 s. Diagnóstico:"
  systemctl --no-pager --lines=15 status sombraviva-api.service >&2 || true
  tail -n 20 "$LOG_DIR/api.log" >&2 || true
  die "Health check falhou"
}

main() {
  instalar_dependencias
  configurar_mysql
  implantar_codigo
  escrever_env
  migrar_e_popular
  criar_servico
  configurar_nginx
  health_check
  log_ok "Aplicação no ar! Dashboard: http://$(hostname -I | awk '{print $1}')/  | Swagger: /docs"
}

main "$@"
