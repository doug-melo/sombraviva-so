# Registro de uso de IA — SombraViva

> Regra da Global Solution: a IA foi usada como copiloto e os prompts estão registrados aqui.
> Cada integrante deve conseguir explicar qualquer parte do código.

| # | Data | Ferramenta | Objetivo |
|---|---|---|---|
| 1 | 17/11/2026 | Claude | Analisar o enunciado da GS e os projetos existentes e listar o que faltava em cada matéria |
| 2 | 17/11/2026 | Claude | Integrar a API de SOA com o ESP32 e com a VM de Operating Systems |
| 3 | 17/11/2026 | Claude | Criar e instalar a VM Ubuntu Server no VirtualBox (depois substituída pela Oracle Cloud) |
| 4 | 18/11/2026 | Claude | Editar o vídeo de IoT: ordenar as gravações, legendar e destacar as partes importantes |
| 5 | 19/11/2026 | Claude | Editar o vídeo de Operating Systems e ajustar a duração dos dois vídeos aos limites |
| 6 | 19/11/2026 | Claude | Abertura animada com a logo, efeitos sonoros e créditos da equipe nos vídeos |
| 7 | 19/11/2026 | Claude | Envio imediato do ESP32 quando o risco muda; evidências, logs e prints da VM na Oracle |

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

> A VM local foi depois substituída por uma instância **Ubuntu Server 24.04 na Oracle Cloud** (Always Free, região São Paulo, IP público), que é a usada na entrega. Os prints do VirtualBox ficaram em `evidencias/prints/historico_virtualbox/`.

## Prompt 4

```
Você deve agir como editor de video e editar o video da entrega da matéria de IOT
análise o contexto e a ordem dos vídeos e coloque eles em perfeita ordem verifique se eu não esqueci de gravar algo
não esqueça de colocar legendas e também outras partes importantes do vídeo
```

**Resultado:** transcrição das gravações, montagem na ordem (problema → arquitetura → demo no Wokwi → ODS), legendas revisadas com os termos técnicos corretos e destaques na tela (níveis de risco, envio HTTP 201, painel). Lista do que faltou gravar (integrantes, explicação dos componentes).

## Prompt 5

```
continue com a edição anterior do vídeo de IOT e depois comece a fazer a mesma coisa com o vídeo de SO
Ainda temos um problema principalmente nos dois vídeos a duração o primeiro a duração ficou um pouco curta e
no segundo a duração ultrapassou o limite faça alguns ajustes para que fique dentro da faixa de gravação
```

**Resultado:** vídeo de SO montado a partir de 9 gravações, com legendas e destaques dos comandos. Duração ajustada aos limites dos roteiros (IoT ≤ 4:00, SO ≤ 7:00): no SO, pausas encurtadas e espera do provisionamento acelerada; no IoT, trechos novos sobre o circuito e a lógica do `sketch.ino`, narrados pelo Douglas a partir de um roteiro curto.

## Prompt 6

```
coloque uma animação melhor no começo [...] coloque a logo da nossa aplicação também dentro desse início
e aplique também efeitos sonoros no começo e coloque a nossa equipe no final do vídeo
```

**Resultado:** abertura animada com a logo do site (folha), nome e frase do projeto, efeitos sonoros sintetizados e créditos com os integrantes e RMs no encerramento dos dois vídeos.

## Prompt 7

```
quando a informação é enviada pelo meu workwi para o meu projeto é somente quanto tem alguma alteração correto?
faça a mudança na lógica do projeto do workwi para quando for detectada alguma mudança dentro os parâmetros
por exemplo do de atenção para o de perigo obviamente também ficar mandando de tempos em tempos
e faltou as partes de evidencias/logs e também a parte das prints
```

**Resultado:** no `sketch.ino` (repositório de IoT), envio imediato quando o nível de risco muda, mantendo o envio a cada 30 s. Neste repositório: `scripts/08_coletar_evidencias.sh` (junta saídas de comandos e logs com tokens mascarados), prints da VM na Oracle tirados das gravações e seção "Decisões do projeto" do README atualizada.

<!-- Integrantes: adicionem abaixo os prompts que cada um usou. -->
