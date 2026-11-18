#!/usr/bin/env bash
# =============================================================================
#  SombraViva — 01_provision_infra.sh
#  Rubrica: "Script de configuração de rede, DNS e IP" (2 pts)
# -----------------------------------------------------------------------------
#  O que faz (tudo idempotente: pode rodar várias vezes sem quebrar nada):
#   1. Define o hostname (sombraviva-srv)
#   2. Atualiza o /etc/hosts com o nome local sombraviva.local
#   3. Configura os servidores DNS no systemd-resolved
#   4. IP: mantém DHCP (padrão seguro) ou aplica IP fixo via netplan
#   5. (Opcional) mDNS com avahi -> sombraviva-srv.local na rede local
#   6. Fuso horário America/Sao_Paulo + sincronização NTP
#   7. Firewall ufw: nega entrada por padrão e libera 22 (limitado), 80 e 8000
#   8. Cria o usuário de sistema 'sombraviva' e os diretórios da aplicação
#
#  Uso:  sudo ./scripts/01_provision_infra.sh
#  Configuração: config/infra.conf
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

require_root "$@"
log_init "01_provision_infra" "$@"
log_banner "01 · Rede, DNS, IP, firewall e usuário"

# ---------------------------------------------------------------- padrões ----
HOSTNAME_SRV="sombraviva-srv"
DOMINIO_LOCAL="sombraviva.local"
TIMEZONE="America/Sao_Paulo"
DNS_SERVIDORES="1.1.1.1 8.8.8.8"
DNS_FALLBACK="9.9.9.9 8.8.4.4"
USAR_IP_ESTATICO="false"
INTERFACE=""
IP_ESTATICO=""
GATEWAY=""
INSTALAR_AVAHI="true"
PORTAS_LIBERADAS="80/tcp 8000/tcp"
PORTA_SSH="22/tcp"
USUARIO_APP="sombraviva"
APP_DIR="/opt/sombraviva"
load_conf "${INFRA_CONF:-$REPO_DIR/config/infra.conf}"

NETPLAN_ARQ="/etc/netplan/60-sombraviva.yaml"
RESOLVED_ARQ="/etc/systemd/resolved.conf.d/sombraviva.conf"
MARCA_INI="# >>> SombraViva (gerenciado por 01_provision_infra.sh) >>>"
MARCA_FIM="# <<< SombraViva <<<"

# Instala pacotes apenas se faltarem
instalar_pacotes() {
  local faltando=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || faltando+=("$pkg")
  done
  if ((${#faltando[@]})); then
    log_info "Instalando: ${faltando[*]}"
    run apt-get update -qq
    DEBIAN_FRONTEND=noninteractive run apt-get install -y -qq "${faltando[@]}"
  else
    log_ok "Pacotes já instalados: $*"
  fi
}

# Interface de rede da rota padrão (ex.: enp0s3)
detectar_interface() {
  ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Primeiro IPv4 da interface
ip_da_interface() {
  ip -o -4 addr show dev "$1" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

# ------------------------------------------------------------------ 1 --------
configurar_hostname() {
  log_step "1/8 Hostname"
  local atual
  atual="$(hostnamectl --static 2>/dev/null || hostname)"
  if [[ "$atual" == "$HOSTNAME_SRV" ]]; then
    log_ok "Hostname já é '$HOSTNAME_SRV'"
  else
    run hostnamectl set-hostname "$HOSTNAME_SRV"
    # Impede que o cloud-init volte o hostname antigo no próximo boot
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      printf 'preserve_hostname: true\n' >/etc/cloud/cloud.cfg.d/99-sombraviva-hostname.cfg
    fi
    log_ok "Hostname alterado: '$atual' -> '$HOSTNAME_SRV'"
    audit "ALTERACAO hostname de=$atual para=$HOSTNAME_SRV"
  fi
}

# ------------------------------------------------------------------ 2 --------
configurar_hosts() {
  log_step "2/8 /etc/hosts e nome local ($DOMINIO_LOCAL)"
  local iface ip_local bloco tmp
  iface="${INTERFACE:-$(detectar_interface)}"
  ip_local="$(ip_da_interface "${iface:-lo}")"
  [[ -f /etc/hosts.sombraviva.bak ]] || cp /etc/hosts /etc/hosts.sombraviva.bak

  bloco="$MARCA_INI
127.0.1.1   ${HOSTNAME_SRV} ${HOSTNAME_SRV}.${DOMINIO_LOCAL} ${DOMINIO_LOCAL}"
  if [[ -n "$ip_local" ]]; then
    bloco+="
${ip_local}   ${DOMINIO_LOCAL} api.${DOMINIO_LOCAL}"
  fi
  bloco+="
$MARCA_FIM"

  # Remove o bloco antigo e linhas 127.0.1.1 herdadas da instalação; insere o novo
  tmp="$(mktemp)"
  awk -v ini="$MARCA_INI" -v fim="$MARCA_FIM" '
    $0==ini {pular=1; next}
    $0==fim {pular=0; next}
    pular!=1 && $1!="127.0.1.1" {print}
  ' /etc/hosts >"$tmp"
  printf '%s\n' "$bloco" >>"$tmp"

  if cmp -s "$tmp" /etc/hosts; then
    log_ok "/etc/hosts já está atualizado"
    rm -f "$tmp"
  else
    cat "$tmp" >/etc/hosts && rm -f "$tmp"
    log_ok "/etc/hosts atualizado (backup em /etc/hosts.sombraviva.bak)"
    audit "ALTERACAO /etc/hosts dominio=$DOMINIO_LOCAL ip=${ip_local:-n/a}"
  fi

  if getent hosts "$DOMINIO_LOCAL" >/dev/null; then
    log_ok "$DOMINIO_LOCAL resolve para: $(getent hosts "$DOMINIO_LOCAL" | awk '{print $1}' | paste -sd' ')"
  else
    log_warn "$DOMINIO_LOCAL ainda não resolve"
  fi
}

# ------------------------------------------------------------------ 3 --------
configurar_dns() {
  log_step "3/8 Servidores DNS (systemd-resolved)"
  if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    log_warn "systemd-resolved não encontrado; DNS não alterado"
    return 0
  fi
  local conteudo
  conteudo="# Gerado por SombraViva 01_provision_infra.sh — $(date '+%Y-%m-%d')
[Resolve]
DNS=${DNS_SERVIDORES}
FallbackDNS=${DNS_FALLBACK}
Domains=${DOMINIO_LOCAL}
DNSStubListener=yes"
  # Compara sem a linha de data para manter a idempotência
  if [[ -f "$RESOLVED_ARQ" ]] && diff -q <(tail -n +2 "$RESOLVED_ARQ") <(printf '%s\n' "$conteudo" | tail -n +2) >/dev/null; then
    log_ok "DNS já configurado: $DNS_SERVIDORES"
  else
    mkdir -p "$(dirname "$RESOLVED_ARQ")"
    printf '%s\n' "$conteudo" >"$RESOLVED_ARQ"
    run systemctl restart systemd-resolved
    log_ok "DNS configurado: $DNS_SERVIDORES (fallback: $DNS_FALLBACK)"
    audit "ALTERACAO dns=$DNS_SERVIDORES fallback=$DNS_FALLBACK"
  fi
  # Teste de resolução externa
  if getent hosts api.open-meteo.com >/dev/null 2>&1; then
    log_ok "Resolução DNS externa OK (api.open-meteo.com)"
  else
    log_warn "Não foi possível resolver api.open-meteo.com — verifique a rede da VM"
  fi
}

# ------------------------------------------------------------------ 4 --------
configurar_ip() {
  log_step "4/8 Endereço IP"
  local iface
  iface="${INTERFACE:-$(detectar_interface)}"
  [[ -n "$iface" ]] || { log_warn "Nenhuma interface com rota padrão encontrada"; return 0; }

  if [[ "$USAR_IP_ESTATICO" == "true" ]]; then
    [[ -n "$IP_ESTATICO" && -n "$GATEWAY" ]] || die "USAR_IP_ESTATICO=true exige IP_ESTATICO e GATEWAY em config/infra.conf"
    local dns_yaml conteudo
    local -a dns_lista
    read -r -a dns_lista <<<"$DNS_SERVIDORES"
    dns_yaml="$(printf '%s, ' "${dns_lista[@]}")"; dns_yaml="${dns_yaml%, }"
    conteudo="# Gerado por SombraViva 01_provision_infra.sh
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses: [${IP_ESTATICO}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
        search: [${DOMINIO_LOCAL}]"
    if escrever_se_mudou "$NETPLAN_ARQ" "$conteudo"; then
      chmod 600 "$NETPLAN_ARQ"
      log_warn "Aplicando IP fixo ${IP_ESTATICO} em ${iface} (conexões SSH podem cair)"
      run netplan generate
      run netplan apply
      audit "ALTERACAO ip_estatico=$IP_ESTATICO gateway=$GATEWAY iface=$iface"
      log_ok "IP fixo aplicado"
    else
      log_ok "IP fixo já configurado (${IP_ESTATICO})"
    fi
  else
    if [[ -f "$NETPLAN_ARQ" ]]; then
      rm -f "$NETPLAN_ARQ"
      run netplan apply
      audit "ALTERACAO ip_estatico_removido iface=$iface"
      log_ok "Configuração de IP fixo removida — voltando para DHCP"
    fi
    log_ok "Mantendo DHCP em ${iface} (padrão seguro). IP atual: $(ip_da_interface "$iface")"
  fi
  log_info "Rota padrão: $(ip -o route show default | head -n1)"
}

# ------------------------------------------------------------------ 5 --------
configurar_mdns() {
  log_step "5/8 mDNS (avahi) — ${HOSTNAME_SRV}.local"
  if [[ "$INSTALAR_AVAHI" != "true" ]]; then
    log_info "INSTALAR_AVAHI=false — pulando"
    return 0
  fi
  instalar_pacotes avahi-daemon
  run systemctl enable --now avahi-daemon
  log_ok "Na rede local (modo Bridge) acesse: http://${HOSTNAME_SRV}.local"
}

# ------------------------------------------------------------------ 6 --------
configurar_fuso() {
  log_step "6/8 Fuso horário e NTP"
  local atual
  atual="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
  if [[ "$atual" != "$TIMEZONE" ]]; then
    run timedatectl set-timezone "$TIMEZONE"
    audit "ALTERACAO timezone de=$atual para=$TIMEZONE"
  fi
  run timedatectl set-ntp true || log_warn "Não foi possível ativar NTP"
  log_ok "Fuso: $TIMEZONE — agora: $(date '+%d/%m/%Y %H:%M:%S %Z')"
}

# ------------------------------------------------------------------ 7 --------
# Imagens Ubuntu da Oracle Cloud trazem regras próprias de iptables
# (/etc/iptables/rules.v4) com um REJECT no fim da cadeia INPUT/FORWARD que
# fica ANTES das cadeias do ufw: tudo além da porta 22 é recusado, mesmo com
# o ufw liberando 80/8000. Removemos só esse REJECT (na hora e no arquivo
# persistido) para que o ufw seja o único firewall da VM.
remover_reject_nuvem() {
  local regra cadeia removeu=0
  for cadeia in INPUT FORWARD; do
    regra="-A $cadeia -j REJECT --reject-with icmp-host-prohibited"
    while iptables -S "$cadeia" 2>/dev/null | grep -qxF -- "$regra"; do
      run iptables -D "$cadeia" -j REJECT --reject-with icmp-host-prohibited
      removeu=1
    done
  done
  if [[ -f /etc/iptables/rules.v4 ]] && grep -q -- "-j REJECT --reject-with icmp-host-prohibited" /etc/iptables/rules.v4; then
    cp -a /etc/iptables/rules.v4 "/etc/iptables/rules.v4.bak.$(date +%Y%m%d%H%M%S)"
    sed -i '/-j REJECT --reject-with icmp-host-prohibited/d' /etc/iptables/rules.v4
    removeu=1
  fi
  if ((removeu)); then
    audit "FIREWALL_NUVEM REJECT padrão da imagem removido (ufw passa a controlar a entrada)"
    log_ok "REJECT da imagem da nuvem removido; o ufw controla as portas"
  else
    log_ok "Sem regras REJECT da imagem da nuvem"
  fi
}

configurar_firewall() {
  log_step "7/8 Firewall (ufw)"
  instalar_pacotes ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  # SSH com 'limit': bloqueia IPs com 6+ conexões em 30 s (força bruta)
  run ufw limit "$PORTA_SSH" comment 'SSH (limitado)'
  local porta
  for porta in $PORTAS_LIBERADAS; do
    run ufw allow "$porta" comment 'SombraViva'
  done
  run ufw logging on
  run ufw --force enable
  remover_reject_nuvem
  audit "FIREWALL ssh=$PORTA_SSH portas='$PORTAS_LIBERADAS'"
  log_ok "Firewall ativo. Regras:"
  ufw status numbered | sed 's/^/      /' >&2
}

# ------------------------------------------------------------------ 8 --------
configurar_usuario() {
  log_step "8/8 Usuário de serviço e diretórios"
  if id "$USUARIO_APP" >/dev/null 2>&1; then
    log_ok "Usuário '$USUARIO_APP' já existe"
  else
    run useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin \
      --comment "SombraViva API" "$USUARIO_APP"
    log_ok "Usuário de sistema '$USUARIO_APP' criado (sem shell de login)"
    audit "USUARIO_CRIADO nome=$USUARIO_APP"
  fi
  install -d -m 755 -o "$USUARIO_APP" -g "$USUARIO_APP" "$APP_DIR"
  install -d -m 750 -o root -g "$USUARIO_APP" /etc/sombraviva
  install -d -m 750 -o root -g adm "$LOG_DIR"
  log_ok "Diretórios: $APP_DIR, /etc/sombraviva, $LOG_DIR"
}

main() {
  configurar_hostname
  configurar_hosts
  configurar_dns
  configurar_ip
  configurar_mdns
  configurar_fuso
  configurar_firewall
  configurar_usuario
  log_step "Resumo da rede"
  log_info "Hostname: $(hostname)  |  FQDN local: ${HOSTNAME_SRV}.${DOMINIO_LOCAL}"
  log_info "IPs: $(hostname -I 2>/dev/null || echo '?')"
  log_info "DNS: $(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2!="" {print $2}' | paste -sd' ' || echo '?')"
  log_ok "Infraestrutura de rede provisionada. Log: $LOG_FILE"
}

main "$@"
