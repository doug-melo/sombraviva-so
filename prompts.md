# Registro de uso de IA — SombraViva

> Regra da Global Solution: a IA foi usada como copiloto e os prompts estão registrados aqui.
> Cada integrante deve conseguir explicar qualquer parte do código.

| # | Data | Ferramenta | Objetivo |
|---|---|---|---|
| 1 | 17/11/2026 | Claude | Analisar o enunciado da GS e os projetos existentes e listar o que faltava em cada matéria |
| 2 | 17/11/2026 | Claude | Integrar a API de SOA com o ESP32 e com a VM de Operating Systems |
| 3 | 17/11/2026 | Claude | Criar e instalar a VM Ubuntu Server no VirtualBox |

## Prompt 1

```
análise esse arquivo que demonstra os trabalhos que eu tenho que realizar e verifique que tipo de
ações eu posso tomar para conseguir realizar perfeitamente a entrega da Global Solution?
a segunda é api desenvolvida para a matéria de SOA
```

**Resultado:** diagnóstico de que o ESP32, a API de SOA e a VM usavam contratos diferentes, e lista de lacunas por critério de avaliação.

## Prompt 2

```
no caso tem que modificar o projeto de SOA para que ele se encaixe dentro do processo de IOT e de SO?
```

**Resultado:** migração Alembic 004 (`iot_devices` e campos de telemetria), endpoint `POST /api/v1/medicoes` compatível com o `sketch.ino`, `GET /api/v1/medicoes/resumo`, `GET /health`, testes novos e `infra/scripts/02_provision_app.sh` passando a implantar a API de SOA com `alembic upgrade head` e seed.

## Prompt 3

```
antes disso eu preciso criar uma VM nesse meu notebook como eu consigo fazer isso?
sim e deixe a vm no ponto que esteja para entrega do trabalho
```

**Resultado:** VM `sombraviva-gs` (Ubuntu Server 26.04, 2 vCPU, 2 GB, NAT com portas 2222→22 e 8080→80) e diagnóstico do Hyper-V travando o VirtualBox.

<!-- Integrantes: adicionem abaixo os prompts que cada um usou. -->
