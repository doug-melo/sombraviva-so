# 🌳 SombraViva — Infraestrutura Linux (Operating Systems)

> **Global Solution FIAP 2026 · CitizenTech** — Inteligência Climática Urbana em Osasco (SP)
>
> Repositório da disciplina **Operating Systems**: provisionamento **100% automatizado** com Shell Script de uma VM Linux que hospeda a API do SombraViva, com rede, DNS, firewall, serviço systemd, monitoramento com alertas e logs de auditoria.

| | |
|---|---|
| **Grupo** | Douglas dos Santos Melo (RM556439) · Henrique Sanches (RM557959) · João Pedro Kraide Máximo (RM563166) · Matheus Marcelino Dantas da Silva (RM556332) · Nicolas Caciolato Reis (RM556506) |
| **Vídeo (6:51)** | <https://youtu.be/LVk2nFlhMOc> |
| **Sistema** | Ubuntu Server 24.04 LTS na **Oracle Cloud** (região São Paulo, Always Free) — os scripts também funcionam numa VM local (VirtualBox), seção 4 |
| **VM no ar** | <http://163.176.235.6/> (dashboard) · <http://163.176.235.6/docs> (Swagger) |
| **Aplicação hospedada** | API do SombraViva, do repositório de SOA: <https://github.com/JoaoKraideM/Global-Solution---4-semestre---Cyber-Soa> |
| **Circuito IoT** | <https://github.com/doug-melo/sombraviva-iot> |
| **Comando único** | `sudo ./provision.sh` |


## Ficha da CitizenTech

| | |
|---|---|
| **Nome** | SombraViva — Inteligência Climática Urbana |
| **Cidade e bairro** | Osasco (SP), Centro — Calçadão da Rua Antônio Agú |
| **Cidadão beneficiado** | Pedestres, trabalhadores de rua, comerciantes e idosos que passam pelo Calçadão; e a prefeitura, que decide onde plantar e sombrear |
| **Problema, em uma frase** | Depois da retirada das árvores do Calçadão, quem passa por ali fica exposto a uma ilha de calor sem saber quando o calor vira risco, e a cidade não tem dados locais para decidir onde devolver a sombra. |
| **Como funciona** | Um ESP32 mede a temperatura na sombra e no piso exposto, calcula o índice de calor e o risco, e envia as leituras para uma API na nuvem; o painel web mostra a diferença em tempo real e o histórico. |
| **O que cada parte faz** | **Operating Systems:** VM Linux na Oracle Cloud provisionada por Shell Script, que hospeda a API com monitoramento, auditoria e recuperação de falhas ([sombraviva-so](https://github.com/doug-melo/sombraviva-so)). **Physical Computing:** circuito ESP32 no Wokwi que mede sombra × sol, sinaliza o risco com LEDs, display e buzzer e envia à API ([sombraviva-iot](https://github.com/doug-melo/sombraviva-iot)). **SOA e Cybersecurity:** API FastAPI + MySQL com Swagger, autenticação dos dispositivos e proteção de dados ([API](https://github.com/JoaoKraideM/Global-Solution---4-semestre---Cyber-Soa)). |
| **Indicador de impacto** | Diferença de temperatura (°C) entre a sombra e o piso exposto e número de horas por dia em ATENÇÃO, ALERTA ou PERIGO no Calçadão. Para ampliar: quantidade de pontos monitorados na cidade. |
| **ODS conectados** | **ODS 3 — Saúde e bem-estar:** avisa quando o índice de calor passa de 27, 32 e 41 °C, faixas em que o NOAA indica fadiga, exaustão e insolação, protegendo quem trabalha e circula ao sol. **ODS 11 — Cidades sustentáveis:** dá à prefeitura dados locais, por ponto da cidade, para priorizar arborização e sombreamento. **ODS 13 — Ação climática:** registra ao longo do tempo a intensidade da ilha de calor, evidência para a adaptação às ondas de calor. |

---

## 1. Visão geral

O **SombraViva** monitora ilhas de calor urbanas. Nasceu da retirada das árvores do Calçadão de Osasco: dois sensores ESP32 (simulados no Wokwi) medem temperatura e umidade em uma **zona arborizada** e no **Calçadão sem vegetação**, e enviam as leituras para uma **API REST (FastAPI + MySQL)**.

Neste repositório essa API é hospedada em uma VM Linux configurada **apenas por scripts Bash**:

- **rede, DNS, IP, hostname, fuso e firewall** → `scripts/01_provision_infra.sh`
- **dependências, MySQL, API (systemd) e Nginx** → `scripts/02_provision_app.sh`
- **monitoramento de CPU, memória, disco, API e MySQL** → `scripts/03_monitor.sh`
- **monitor como serviço systemd tolerante a falhas + auditoria** → `scripts/04_setup_monitoring.sh`
- **testes de falha** (kill -9, CPU, disco, MySQL) → `scripts/05_teste_falha.sh`
- **túnel público para o Wokwi** (opcional) → `scripts/06_tunnel.sh`
- **deploy automático** (a VM busca o GitHub a cada 2 min e reimplanta) → `scripts/07_auto_deploy.sh`

## 2. Arquitetura

```mermaid
flowchart LR
    subgraph Wokwi["☁️ Wokwi (Physical Computing)"]
        ESP["ESP32<br/>2x DHT22 + LDR<br/>OLED, LEDs, buzzer"]
    end
    subgraph Internet
        TUN["Cloudflare Quick Tunnel<br/>(06_tunnel.sh)"]
        OM["Open-Meteo<br/>(temperatura oficial)"]
    end
    subgraph VM["🖥️ VM Ubuntu Server — sombraviva-srv"]
        UFW["ufw<br/>22 (limit) · 80 · 8000"]
        NGX["Nginx :80<br/>proxy reverso"]
        API["sombraviva-api.service<br/>FastAPI + Uvicorn :8000<br/>Restart=always"]
        DB[("MySQL 8<br/>banco sombraviva")]
        MON["sombraviva-monitor.service<br/>03_monitor.sh --loop"]
        GUARD["sombraviva-monitor-guard.timer<br/>(a cada 2 min)"]
        LOGS["/var/log/sombraviva/<br/>monitor · alertas · auditoria · api"]
        AUD["auditd + logrotate"]
    end
    ESP -- "HTTPS POST /api/v1/medicoes<br/>Bearer token + X-Device-Id" --> TUN
    ESP -. "GET clima atual" .-> OM
    TUN --> UFW --> NGX --> API --> DB
    USER["👩‍💻 Navegador<br/>Dashboard / Swagger"] --> UFW
    MON -- "GET /health" --> API
    MON -- "CPU · memória · disco<br/>systemctl · mysqladmin" --> LOGS
    GUARD -- "reinicia se falhar" --> MON
    API --> LOGS
    AUD --> LOGS
```

### Como se conecta com as outras disciplinas

| Disciplina | Ligação com este repositório |
|---|---|
| **Physical Computing (IoT)** | O ESP32 do Wokwi faz `POST /api/v1/medicoes` nesta API (mesmo JSON e cabeçalhos do `sketch.ino`). Basta trocar o `API_URL` do sketch pela URL pública do túnel. |
| **SOA / Web Services** | A aplicação hospedada é o backend de SOA ([Global-Solution---4-semestre---Cyber-Soa](https://github.com/JoaoKraideM/Global-Solution---4-semestre---Cyber-Soa)): o `02_provision_app.sh` clona o repositório, roda as migrações Alembic e o seed e sobe a API no systemd. |
| **Cybersecurity** | Autenticação dos dispositivos por token (comparação em tempo constante), **401 + registro de auditoria** em toda tentativa inválida (log + tabela `eventos_auditoria`), firewall, segredos em arquivo `600`, serviços com *hardening* do systemd, auditd e trilha de quem executou cada script. |

## 3. A aplicação hospedada (repositório de SOA)

O código da API **não fica neste repositório**: ele é o entregável de SOA e é clonado pelo `02_provision_app.sh` (`APP_GIT_URL` em `config/app.conf`). Assim, a VM sempre hospeda a mesma API que foi avaliada em SOA.

| Método | Rota | Uso nesta infraestrutura |
|---|---|---|
| `GET` | `/` e `/admin` | Portal climático e central de Cybersecurity |
| `GET` | `/health` | Saúde da API **e do MySQL** (200 = ok, 503 = banco fora). Usado pelo monitor e pelo teste de falha |
| `POST` | `/api/v1/medicoes` | Recebe as medições do ESP32. Exige `Authorization: Bearer <token>` + `X-Device-Id`. Token inválido → **401** e evento de segurança |
| `GET` | `/api/v1/medicoes/resumo` | Diferença Calçadão × zona arborizada e nível de risco atual |
| `GET` | `/docs` | Swagger (documentação automática) |

As mudanças da integração ESP32 + VM, do redesenho do painel e da central, dos testes do frontend e da pipeline DevSecOps já estão na `main` da API (PR #1). Os patches usados até o merge ficam em `patches/aplicados/` como histórico. O `02_provision_app.sh` só aplica patches soltos em `patches/`. Hoje não há nenhum: de `0001` a `0012`, todos entraram na `main` da API (PRs #1 e #2) e ficam em `patches/aplicados/`. Se um patch novo entrar por PR antes de sair desta pasta, o script reconhece o commit de mesmo assunto na `main` e pula o patch.

O que o `02_provision_app.sh` faz com ela, em ordem: instala Python, MySQL e Nginx → cria banco e usuário com menor privilégio → clona a API e aplica os patches → cria o `venv` → gera `/etc/sombraviva/sombraviva.env` (chmod 600, segredos aleatórios) → `alembic upgrade head` → `python -m app.seed` → serviço systemd → Nginx → health check.

### Mudar as variáveis de ambiente na VM

O `/etc/sombraviva/sombraviva.env` é regerado a cada deploy a partir do `config/app.conf`, então editar esse arquivo direto não dura. Os ajustes da VM ficam em `/etc/sombraviva/app.local.conf`, fora do Git, lido depois do `app.conf`, com os mesmos nomes do `.env.example` da API (dá para colar as linhas do seu `.env`). O que não estiver nele continua reaproveitado do `.env` atual (JWT, chaves dos sensores, senhas do admin e do banco). Uma `ADMIN_PASSWORD` definida ali também atualiza o admin que já existe no banco.

```bash
sudo cp ~/sombraviva-so/config/app.local.conf.exemplo /etc/sombraviva/app.local.conf
sudo chmod 600 /etc/sombraviva/app.local.conf
sudo nano /etc/sombraviva/app.local.conf      # descomente e ajuste o que precisar
sudo ~/sombraviva-so/scripts/07_auto_deploy.sh --force
```

### Deploy automático

Depois do primeiro provisionamento, `sudo ./scripts/07_auto_deploy.sh --install` liga o `sombraviva-deploy.timer`. A cada 2 minutos a VM compara o último commit implantado com o GitHub, nas duas fontes: este repositório (scripts, configuração e patches) e a `main` da API de SOA. Se algo mudou, ela atualiza este clone com fast-forward e roda o `02_provision_app.sh`, que reaplica os patches, migra o banco, reinicia a API e testa o `/health`. Se o deploy falhar, o script volta este repositório para o commit anterior e reimplanta, para o site não ficar fora do ar. A VM só busca do GitHub; nenhuma chave ou porta extra é aberta para o GitHub entrar nela.

```bash
sudo ./scripts/07_auto_deploy.sh --install   # liga o timer
sudo ./scripts/07_auto_deploy.sh --status    # último deploy e próximo disparo
sudo ./scripts/07_auto_deploy.sh --force     # reimplanta agora
journalctl -t sombraviva-audit | grep DEPLOY # histórico de deploys
```

## 4. Requisitos

- **VirtualBox** 7.x (ou VMware/Hyper-V/UTM)
- **ISO Ubuntu Server 26.04 LTS** (ou 24.04 LTS) — <https://ubuntu.com/download/server>
- VM sugerida: **2 vCPU, 2 GB de RAM (4 GB ideal), disco de 20 GB**
- Internet na VM (para `apt` e `pip`)

### Rede da VM no VirtualBox

| Modo | Quando usar | Como acessar da sua máquina |
|---|---|---|
| **Placa em modo Bridge** (recomendado) | Rede de casa/escritório | A VM recebe um IP da sua rede (ex.: `192.168.0.37`). Acesse `http://IP-DA-VM/` ou `http://sombraviva-srv.local/` (mDNS) |
| **NAT + Port Forwarding** | Rede da FIAP / Wi-Fi que bloqueia bridge | Em *Configurações → Rede → Avançado → Redirecionamento de Portas* crie: `SSH 2222 → 22`, `HTTP 8080 → 80`, `API 8000 → 8000`. Acesse `http://localhost:8080/` e `ssh -p 2222 usuario@localhost` |

> Para usar o nome `sombraviva.local` também no seu computador, adicione `IP-DA-VM  sombraviva.local` no arquivo hosts (Windows: `C:\Windows\System32\drivers\etc\hosts`; Linux/macOS: `/etc/hosts`).

## Decisões do projeto (com evidências)

Prints da VM usada na entrega, tirados das gravações do vídeo (pasta [`evidencias/prints/`](evidencias/prints/)). As saídas completas dos comandos e os logs estão em [`evidencias/logs/`](evidencias/logs/) (gerados por `sudo ./scripts/08_coletar_evidencias.sh`).

| Decisão | Por quê | Evidência |
|---|---|---|
| **Oracle Cloud, região São Paulo, plano Always Free** | A VM fica ligada 24 h sem custo, perto dos usuários (latência baixa) e com **IP público**: o ESP32 no Wokwi chega direto à API, sem depender do notebook ligado nem de túnel | ![](evidencias/prints/11_oracle_instancia_detalhes.png) |
| **Ubuntu Server 24.04 LTS, sem interface gráfica** | Versão LTS com suporte até 2029; sem GUI sobra memória para MySQL, API e Nginx | ![](evidencias/prints/11_oracle_instancia_detalhes.png) |
| **1 OCPU e 1 GB de RAM** (shape gratuito) | Suficiente para MySQL + Uvicorn + Nginx com o volume de dados do projeto; o monitor alerta se memória ou CPU passarem do limite | ![](evidencias/prints/26_monitor_systemctl_status.png) |
| **IP privado por DHCP + IP público da Oracle** | A VNIC recebe `10.0.0.241` na sub-rede; o IP público é associado pela Oracle. Fixar IP pelo netplan não traz ganho na nuvem e pode derrubar o SSH (o script ainda suporta IP fixo) | ![](evidencias/prints/12_oracle_vnic_ip_publico.png) |
| **Toda a configuração em `config/*.conf`** | Hostname, DNS, firewall, usuário de serviço e limites do monitor mudam sem editar os scripts | ![](evidencias/prints/13_github_infra_conf.png) ![](evidencias/prints/14_github_monitor_conf.png) |
| **Um comando provisiona tudo** (`sudo ./provision.sh`) | Rede, DNS, firewall, usuário, MySQL, API, systemd, Nginx e monitoramento, com log colorido e resumo final | ![](evidencias/prints/15_provision_01_infra.png) ![](evidencias/prints/16_provision_02_app.png) ![](evidencias/prints/17_provision_resumo.png) |
| **Hostname `sombraviva-srv` e nome local `sombraviva.local`** | O mesmo nome em `/etc/hosts`, mDNS e configuração da API | ![](evidencias/prints/18_hostname_ip_hosts.png) |
| **DNS 1.1.1.1 / 8.8.8.8 com reserva 9.9.9.9 / 8.8.4.4** | Dois provedores diferentes: se um cair, a VM continua resolvendo a Open-Meteo e o GitHub | ![](evidencias/prints/19_dns_firewall.png) |
| **UFW: entrada negada por padrão; só 22 (limitado), 80 e 8000** | Superfície mínima; o `limit` no SSH bloqueia força bruta | ![](evidencias/prints/19_dns_firewall.png) |
| **Segredos em `/etc/sombraviva/sombraviva.env` com `chmod 600`, dono root** | Senha do banco e tokens fora do Git e legíveis só pelo root/systemd | ![](evidencias/prints/20_env_permissao_600.png) |
| **Nginx na porta 80 na frente da API** | Proxy reverso: dashboard, Swagger e `/api` no mesmo endereço | ![](evidencias/prints/21_dashboard_publico.png) ![](evidencias/prints/23_swagger_endpoints.png) |
| **Integração com o ESP32 (IoT)** | O Wokwi envia `POST /api/v1/medicoes` com token Bearer (HTTP 201) e o painel atualiza | ![](evidencias/prints/24_wokwi_http201.png) ![](evidencias/prints/22_admin_estacoes_iot.png) ![](evidencias/prints/25_dashboard_leituras_esp32.png) |
| **Monitor como serviço systemd (`Restart=always`)** | Verifica CPU, memória, disco, API, Nginx e MySQL a cada 30 s e volta sozinho se for morto | ![](evidencias/prints/26_monitor_systemctl_status.png) ![](evidencias/prints/27_monitor_service_restart_always.png) ![](evidencias/prints/28_monitor_log_tail.png) |
| **Testes de falha automatizados** | kill -9 na API e no monitor, CPU, disco cheio e MySQL fora do ar — todos PASSOU | ![](evidencias/prints/29_teste_falha_resumo.png) |
| **Auditoria em três camadas** | `auditoria.log` (quem, quando, argumentos, hash, resultado), journal com os alertas e `auditd` vigiando o `.env` | ![](evidencias/prints/30_auditoria_log.png) ![](evidencias/prints/31_journal_alertas.png) ![](evidencias/prints/32_ausearch_auditd.png) |
| **logrotate diário com 14 rotações** | Os logs não enchem o disco de 45 GB da VM | ![](evidencias/prints/33_logrotate.png) |
| **Deploy automático a cada 2 min com rollback** | Cada push no GitHub chega à VM sozinho; se o deploy falhar, volta ao commit anterior | ![](evidencias/prints/34_auto_deploy_status.png) |

> **Histórico:** a primeira versão da VM foi criada localmente no VirtualBox (Ubuntu 26.04, 2 vCPU, 2 GB, NAT). Ela foi trocada pela Oracle Cloud porque o notebook precisava ficar ligado e o Hyper-V travava o boot. Os prints dessa tentativa estão em [`evidencias/prints/historico_virtualbox/`](evidencias/prints/historico_virtualbox/).

## 5. Passo a passo (do zero ao ar em ~20 min)

1. **Crie a VM** no VirtualBox (Linux → Ubuntu 64-bit, 2 vCPU, 2–4 GB, 20 GB) e escolha a rede (seção 4).
2. **Instale o Ubuntu Server** com as opções padrão. Marque **"Install OpenSSH server"**. Usuário sugerido: `fiap`.
3. Entre na VM (pelo console ou `ssh`) e rode:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/doug-melo/sombraviva-so.git
cd sombraviva-so
sudo ./provision.sh
```

> Se o repositório foi enviado pelo site do GitHub ou extraído no Windows e aparecer `Permission denied`, rode `sudo bash provision.sh` (ele mesmo aplica `chmod +x` nos scripts).

4. Ao final aparece o **resumo** com URLs, status dos serviços e o health check. Abra no navegador `http://IP-DA-VM/`.
5. Envie medições de teste (sem Wokwi): `./scripts/simular_esp32.sh -n 10 -i 2`
6. Rode os testes de falha: `sudo ./scripts/05_teste_falha.sh`

Opções úteis:

```bash
sudo ./provision.sh --simular      # já envia medições de exemplo no fim
sudo ./provision.sh --sem-rede     # reinstala só app + monitoramento
sudo ./scripts/02_provision_app.sh # cada script também roda sozinho (idempotente)
```

### O que você pode (ou deve) ajustar

| Arquivo | Variável | Para quê |
|---|---|---|
| `config/infra.conf` | `USAR_IP_ESTATICO`, `IP_ESTATICO`, `GATEWAY` | IP fixo (padrão: DHCP, mais seguro) |
| `config/infra.conf` | `DNS_SERVIDORES`, `HOSTNAME_SRV`, `DOMINIO_LOCAL` | DNS e nomes |
| `config/app.conf` | `SOMBRAVIVA_DEVICE_TOKENS` | **Deve bater com `DEVICE_ID`/`DEVICE_TOKEN` do sketch.ino** |
| `config/app.conf` | `DB_PASSWORD` | Vazio = senha forte gerada e reaproveitada |
| `config/monitor.conf` | `CPU_WARN`, `MEM_WARN`, `DISCO_WARN`… | Limites dos alertas |

## 6. Rubrica × arquivos

| Critério (Operating Systems) | Pts | Onde está |
|---|---|---|
| Script de configuração de **rede, DNS e IP** | 2,0 | `scripts/01_provision_infra.sh` + `config/infra.conf` — hostname, `/etc/hosts`, `sombraviva.local`, DNS no systemd-resolved, DHCP ou IP fixo via netplan, mDNS, fuso, **ufw**, usuário de serviço |
| Script de **instalação de dependências e deploy** da aplicação | 2,0 | `scripts/02_provision_app.sh` + `config/app.conf` — apt, MySQL (banco/usuário), venv + pip, `.env` 600, `sombraviva-api.service`, Nginx, health check |
| Script de **monitoramento com alertas** de CPU, disco e memória | 2,0 | `scripts/03_monitor.sh` + `config/monitor.conf` — INFO/WARN/CRIT em `monitor.log`, `alertas.log` e syslog; também checa `/health`, serviços e MySQL |
| Monitoramento como **serviço systemd tolerante a falhas** | 1,0 | `systemd/sombraviva-monitor.service` (`Restart=always`, `RestartSec`, `StartLimit*`, `OOMScoreAdjust`, hardening) + `systemd/sombraviva-monitor-guard.timer` — instalados por `scripts/04_setup_monitoring.sh` |
| **Logs de auditoria** e de execução | 1,0 | `scripts/lib/log.sh` (cada script registra quem/quando/o quê/hash/código de saída em `auditoria.log` + syslog), `auditd/sombraviva.rules`, `logrotate/sombraviva` |
| **Funcionamento completo** (provisionamento automático na VM) | 2,0 | `provision.sh` (comando único) + `scripts/05_teste_falha.sh` + vídeo (`docs/roteiro_video_os.md`) |

## 7. Ligando o Wokwi (ESP32) a esta API

O Wokwi roda na internet e **não enxerga a sua VM**. É preciso uma URL pública:

**Opção A — Cloudflare Quick Tunnel (recomendado, sem conta):**

```bash
sudo ./scripts/06_tunnel.sh
# mostra algo como: https://palavras-aleatorias.trycloudflare.com
```

**Opção B — ngrok** (precisa de conta gratuita e authtoken):

```bash
sudo snap install ngrok        # ou veja https://ngrok.com/download
ngrok config add-authtoken SEU_TOKEN
ngrok http 80
```

Depois, no `sketch.ino` do projeto Wokwi, troque **só** a URL (deixe o túnel aberto enquanto grava):

```cpp
const char* API_URL = "https://palavras-aleatorias.trycloudflare.com/api/v1/medicoes";
const char* DEVICE_ID    = "esp32-osasco-calcadao-01";   // igual ao config/app.conf
const char* DEVICE_TOKEN = "sv-dev-TROQUE-ESTE-TOKEN";    // igual ao config/app.conf
```

No Serial Monitor do Wokwi deve aparecer `[API] ... enviado (HTTP 201)` e as leituras surgem no dashboard. A URL do quick tunnel muda a cada execução.

## 8. Trocando a origem da API

Por padrão a API vem do GitHub (`APP_ORIGEM="git"`, `APP_GIT_URL` em `config/app.conf`). Para usar uma cópia local, defina `APP_ORIGEM="local"` e `APP_FONTE="/caminho/da/api"`. Depois de qualquer mudança: `sudo ./scripts/02_provision_app.sh` (idempotente; reaplica migrações e reinicia o serviço).

## 9. Evidências — onde estão e como mostrar

Todos os logs ficam em **`/var/log/sombraviva/`** (rotacionados diariamente, 14 cópias):

| Arquivo | Conteúdo |
|---|---|
| `provision.log`, `01_…log`, `02_…log`, `04_…log` | Execução de cada script, com data/hora e saída completa dos comandos |
| `auditoria.log` | Quem executou cada script (`SUDO_USER`), quando, onde, argumentos, hash, resultado |
| `monitor.log` | Todas as verificações (CPU, memória, disco, API, serviços, MySQL) |
| `alertas.log` | Só os WARN/CRIT |
| `api.log` | Log da API (inclui `ACESSO_NEGADO` e `ALERTA_CALOR`) |
| `05_teste_falha.log` | Resultado dos testes de falha |

**Para a entrega**, um comando junta tudo isso (saídas + logs, com tokens mascarados) em `~/evidencias_sombraviva.tar.gz`, que vai para [`evidencias/logs/`](evidencias/logs/):

```bash
sudo ./scripts/08_coletar_evidencias.sh
```

Comandos individuais (vídeo / prints):

```bash
hostnamectl; ip -br a; resolvectl status | head -20; getent hosts sombraviva.local
sudo ufw status verbose
systemctl status sombraviva-api sombraviva-monitor nginx mysql --no-pager
systemctl list-timers sombraviva-monitor-guard.timer
sudo tail -f /var/log/sombraviva/monitor.log
sudo cat /var/log/sombraviva/alertas.log
sudo tail /var/log/sombraviva/auditoria.log
journalctl -t sombraviva-monitor -p warning --since today
journalctl -t sombraviva-audit --since today
sudo ausearch -k sombraviva_config -i | tail -20     # auditd
sudo grep ACESSO_NEGADO /var/log/sombraviva/api.log
curl -s localhost/api/v1/resumo | python3 -m json.tool
sudo stat -c '%A %U %n' /etc/sombraviva/sombraviva.env  # -rw------- root
```

## 10. Estrutura do repositório

```
sombraviva-so/
├── provision.sh                 # comando único: roda tudo em ordem + resumo
├── config/      infra.conf · app.conf · monitor.conf
├── scripts/
│   ├── lib/log.sh               # log colorido + auditoria compartilhados
│   ├── 01_provision_infra.sh    # rede, DNS, IP, firewall, usuário
│   ├── 02_provision_app.sh      # deps, MySQL, venv, systemd, Nginx
│   ├── 03_monitor.sh            # monitoramento (once / loop)
│   ├── 04_setup_monitoring.sh   # serviço do monitor, auditd, logrotate
│   ├── 05_teste_falha.sh        # testes de falha
│   ├── 06_tunnel.sh             # URL pública para o Wokwi (opcional)
│   ├── 07_auto_deploy.sh        # deploy contínuo: verifica o GitHub a cada 2 min
│   ├── 08_coletar_evidencias.sh # junta saídas de comandos e logs (mascarados) para a entrega
│   └── simular_esp32.sh         # envia medições falsas com token
├── systemd/     sombraviva-api.service · sombraviva-monitor.service · guard .service/.timer
├── nginx/sombraviva.conf  ·  auditd/sombraviva.rules  ·  logrotate/sombraviva
├── docs/roteiro_video_os.md     # roteiro do vídeo de 7 min
├── patches/aplicados/           # histórico: 0001 a 0012 já estão na main da API (PRs #1 e #2)
├── evidencias/                  # prints (prints/) e logs exportados da VM (logs/)
└── prompts.md                   # registro dos prompts de IA (regra da GS)
```

## 11. Validação local dos scripts (sem VM)

```bash
shellcheck -x -P scripts provision.sh scripts/*.sh          # análise estática dos scripts
LOG_DIR=/tmp/svlogs HEALTH_URL=http://localhost:8000/health ./scripts/03_monitor.sh   # com a API de SOA rodando localmente
./scripts/simular_esp32.sh -u http://localhost:8000
```

## 12. Boas práticas e regras da GS

- Somente **dados simulados**: nenhum dado pessoal real é coletado.
- Segredos (senha do banco, tokens) **nunca** vão para o Git — ficam em `/etc/sombraviva/sombraviva.env` (`chmod 600`).
- Uso de IA registrado em [`prompts.md`](prompts.md).
- ODS 3, 11 e 13 — como o projeto contribui para cada um está na [Ficha da CitizenTech](#ficha-da-citizentech).
