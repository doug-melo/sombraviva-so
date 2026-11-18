# Evidências

Coloque aqui os prints e logs exportados da VM para a entrega:

| Arquivo sugerido | Como gerar |
|---|---|
| `01_rede_dns.png` | `hostnamectl; ip -br a; resolvectl status; getent hosts sombraviva.local` |
| `02_firewall.png` | `sudo ufw status verbose` |
| `03_servicos.png` | `systemctl status sombraviva-api sombraviva-monitor nginx mysql --no-pager` |
| `04_dashboard.png` | navegador em `http://IP-DA-VM/` |
| `05_swagger.png` | navegador em `http://IP-DA-VM/docs` |
| `06_monitor_alertas.png` | `sudo tail -n 30 /var/log/sombraviva/monitor.log` durante o teste de CPU |
| `07_teste_falha.png` | saída do `sudo ./scripts/05_teste_falha.sh` (resumo final) |
| `08_auditoria.png` | `sudo tail /var/log/sombraviva/auditoria.log` e `sudo ausearch -k sombraviva_config -i` |
| `09_wokwi_http201.png` | Serial Monitor do Wokwi mostrando `HTTP 201` |
| `logs/` | `sudo cp /var/log/sombraviva/*.log evidencias/logs/ && sudo chown -R $USER evidencias/logs` |

> Antes de versionar logs, confira se nenhum contém senha ou token real.
