# 🎬 Roteiro do vídeo — Operating Systems (até 7 minutos)

**Objetivo:** mostrar o ambiente sendo provisionado **sozinho** dentro da VM, a aplicação no ar, o monitoramento com alertas, a tolerância a falhas e os logs de auditoria.

**Preparação (antes de gravar):**
- VM Ubuntu Server recém-instalada, já com `git` e o repositório clonado (ou clone ao vivo).
- Terminal com fonte grande (Ctrl + `+`), navegador aberto na máquina real.
- Deixe o `provision.sh` rodar uma vez antes, para os pacotes ficarem em cache — ou acelere o trecho de instalação na edição (avise com uma legenda "⏩ acelerado").
- Opcional: abrir uma segunda aba SSH para o `tail -f` do monitor.

| Tempo | Cena | O que mostrar / falar |
|---|---|---|
| **0:00 – 0:30** | Abertura | Grupo, problema (retirada das árvores do Calçadão de Osasco → ilhas de calor) e o que esta parte entrega: "uma VM Linux configurada 100% por Shell Script que hospeda a API do SombraViva". |
| **0:30 – 1:00** | Repositório | `tree -L 2` ou o GitHub: `provision.sh`, `scripts/01…06`, `config/`, `systemd/`. Mostrar rapidamente `config/infra.conf` e `config/monitor.conf` (limites). |
| **1:00 – 2:30** | Provisionamento | `sudo ./provision.sh`. Enquanto roda, comentar as etapas coloridas: hostname, `/etc/hosts`, DNS, DHCP/IP fixo, fuso, ufw, usuário `sombraviva`; depois MySQL, venv, `.env` 600, serviço systemd, Nginx e health check. Mostrar o **resumo final** com URLs e serviços verdes. |
| **2:30 – 3:15** | Rede e segurança | `hostnamectl`, `ip -br a`, `getent hosts sombraviva.local`, `resolvectl status \| head`, `sudo ufw status verbose`, `sudo stat -c '%A %U %n' /etc/sombraviva/sombraviva.env`. |
| **3:15 – 4:00** | Aplicação no ar | Navegador em `http://IP-DA-VM/` (dashboard) e `/docs` (Swagger). Rodar `./scripts/simular_esp32.sh --calor -n 3 -i 1` e ver o dashboard atualizar com **ilha de calor** e risco. Rodar `--token-invalido` → **401** e mostrar `sudo grep ACESSO_NEGADO /var/log/sombraviva/api.log`. *(Se tiver o Wokwi ligado via `06_tunnel.sh`, mostre o Serial com HTTP 201 — 15 s.)* |
| **4:00 – 4:45** | Monitoramento | `systemctl status sombraviva-monitor`, mostrar `Restart=always` em `systemd/sombraviva-monitor.service`, `sudo tail -f /var/log/sombraviva/monitor.log` com as linhas INFO de CPU, memória, disco, API e MySQL. |
| **4:45 – 6:15** | **Testes de falha** | `sudo ./scripts/05_teste_falha.sh` e comentar: **(1)** `kill -9` na API → systemd sobe novo PID e `/health` volta 200; **(2)** `kill -9` no monitor → reinicia; **(3)** estresse de CPU → alerta **WARN/CRIT**; **(4)** disco cheio (arquivo temporário) → alerta e limpeza; **(5)** MySQL parado → `/health` 503 + **CRIT** → banco religado e API reconecta. Mostrar o **resumo** com todos "PASSOU". |
| **6:15 – 6:45** | Auditoria e logs | `ls /var/log/sombraviva`, `sudo tail /var/log/sombraviva/auditoria.log` (quem executou, quando, hash, resultado), `journalctl -t sombraviva-monitor -p warning --since today`, `sudo ausearch -k sombraviva_config -i \| tail`, `cat /etc/logrotate.d/sombraviva`. |
| **6:45 – 7:00** | Fechamento | "Um comando provisiona tudo, o sistema se recupera sozinho de falhas e tudo fica auditado. A mesma API recebe os dados do ESP32 (IoT) e é a base do backend de SOA." Integrantes e link do repositório. |

**Dicas**
- Fale o **número do critério** da rubrica quando ele aparecer (ex.: "aqui está o item de monitoramento como serviço systemd").
- Se a VM for lenta, rode os testes individualmente: `sudo ./scripts/05_teste_falha.sh api mysql`.
- Grave com OBS Studio; exporte em 1080p e confira se ficou **abaixo de 7:00**.
