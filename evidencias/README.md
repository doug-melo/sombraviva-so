# Evidências

Tudo aqui vem da VM da entrega: **Oracle Cloud, região São Paulo, Ubuntu Server 24.04 LTS** (`sombraviva-srv`, IP público `163.176.235.6`).

## Prints (`prints/`)

Tirados das gravações do vídeo, em 1080p. O token do dispositivo no print do Wokwi foi coberto.

| Print | O que mostra |
|---|---|
| `11_oracle_instancia_detalhes.png` | Instância na Oracle: Ubuntu 24.04, região São Paulo, em execução |
| `12_oracle_vnic_ip_publico.png` | VNIC com IP público e IP privado `10.0.0.241` |
| `13_github_infra_conf.png` | `config/infra.conf`: hostname, DNS, IP, firewall, usuário |
| `14_github_monitor_conf.png` | `config/monitor.conf`: intervalo e limites de alerta |
| `15_provision_01_infra.png` | `sudo ./provision.sh` — etapa 01 (rede, DNS, firewall, usuário) |
| `16_provision_02_app.png` | Etapa 02 (MySQL, API, systemd, Nginx) |
| `17_provision_resumo.png` | Resumo final: serviços `active` e health check OK |
| `18_hostname_ip_hosts.png` | `hostnamectl`, `ip -br a`, `getent hosts sombraviva.local` |
| `19_dns_firewall.png` | `resolvectl status` e `ufw status verbose` |
| `20_env_permissao_600.png` | `.env` com `-rw------- root` |
| `21_dashboard_publico.png` | Dashboard público servido pela VM |
| `22_admin_estacoes_iot.png` | Central de segurança: estações e credenciais IoT |
| `23_swagger_endpoints.png` | Swagger (`/docs`) com os endpoints |
| `24_wokwi_http201.png` | ESP32 no Wokwi recebendo `HTTP 201` da API |
| `25_dashboard_leituras_esp32.png` | Leituras do ESP32 no painel |
| `26_monitor_systemctl_status.png` | `systemctl status sombraviva-monitor` |
| `27_monitor_service_restart_always.png` | Unit do monitor com `Restart=always` |
| `28_monitor_log_tail.png` | `tail -f monitor.log`: CPU, memória, disco, API, MySQL |
| `29_teste_falha_resumo.png` | `05_teste_falha.sh`: os 5 testes PASSOU |
| `30_auditoria_log.png` | `auditoria.log`: quem, quando, argumentos, hash, resultado |
| `31_journal_alertas.png` | `journalctl -t sombraviva-monitor -p warning` |
| `32_ausearch_auditd.png` | `ausearch -k sombraviva_config` (auditd vigiando o `.env`) |
| `33_logrotate.png` | `/etc/logrotate.d/sombraviva` |
| `34_auto_deploy_status.png` | `07_auto_deploy.sh --status` e o timer do deploy |

`prints/historico_virtualbox/` guarda os prints da primeira VM, criada no VirtualBox antes da migração para a Oracle Cloud.

## Logs (`logs/`)

Gerados na VM com um comando, que só lê (não altera nada) e mascara tokens, senhas e cabeçalhos `Bearer`:

```bash
cd ~/sombraviva-so
sudo ./scripts/08_coletar_evidencias.sh      # cria ~/evidencias_sombraviva.tar.gz
```

| Arquivo | Conteúdo |
|---|---|
| `01_sistema.txt` | `hostnamectl`, kernel, versão do Ubuntu, CPU, memória, disco |
| `02_rede_dns.txt` | interfaces, rotas, `/etc/hosts`, `resolvectl`, resolução de nomes |
| `03_firewall.txt` | `ufw status verbose` e portas em escuta |
| `04_servicos.txt` | status dos serviços, timers e política de reinício (`Restart`, `NRestarts`) |
| `05_usuarios_permissoes.txt` | usuário de serviço `sombraviva`, permissões do `.env` e das pastas |
| `06_aplicacao_health.txt` | `/health`, `/api/v1/resumo` e `/docs` |
| `07_journal_alertas.txt` | alertas WARN/CRIT do dia no journal e eventos de auditoria |
| `08_auditd.txt` | regras do auditd e alterações registradas no `.env` |
| `09_logrotate.txt` | configuração e simulação do logrotate |
| `10_auto_deploy.txt` | situação do deploy automático e últimas execuções |
| `logs/*.log` | últimas 2000 linhas de cada log em `/var/log/sombraviva` (`monitor`, `alertas`, `auditoria`, `api`, `05_teste_falha`, `07_auto_deploy`…) |
