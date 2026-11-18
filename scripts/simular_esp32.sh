#!/usr/bin/env bash
# =============================================================================
#  SombraViva — simular_esp32.sh
#  Simula o ESP32 do Wokwi enviando medições para a API (sem precisar do Wokwi).
#  Envia o MESMO JSON e os MESMOS cabeçalhos do sketch.ino:
#     Authorization: Bearer <token>   +   X-Device-Id: <device>
#
#  Uso:
#   ./scripts/simular_esp32.sh                      # 5 ciclos em http://localhost
#   ./scripts/simular_esp32.sh -n 20 -i 2           # 20 ciclos, 2 s entre eles
#   ./scripts/simular_esp32.sh -u https://xxxx.trycloudflare.com
#   ./scripts/simular_esp32.sh --calor              # força cenário de calor extremo
#   ./scripts/simular_esp32.sh --token-invalido     # demonstra o 401 + auditoria
#
#  Não precisa de root.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "$SCRIPT_DIR/lib/log.sh"

URL_BASE="${URL_BASE:-http://localhost}"
DEVICE_ID="${DEVICE_ID:-esp32-osasco-calcadao-01}"
DEVICE_TOKEN="${DEVICE_TOKEN:-sv-dev-TROQUE-ESTE-TOKEN}"
CICLOS=5
INTERVALO=3
CENARIO="normal"

uso() { sed -n '2,17p' "$0"; exit 0; }

while (($#)); do
  case "$1" in
    -u|--url)         URL_BASE="$2"; shift 2 ;;
    -n|--ciclos)      CICLOS="$2"; shift 2 ;;
    -i|--intervalo)   INTERVALO="$2"; shift 2 ;;
    -d|--device)      DEVICE_ID="$2"; shift 2 ;;
    -t|--token)       DEVICE_TOKEN="$2"; shift 2 ;;
    --calor)          CENARIO="calor"; shift ;;
    --token-invalido) DEVICE_TOKEN="token-falso-$RANDOM"; CICLOS=1; shift ;;
    -h|--help)        uso ;;
    *) die "Opção inválida: $1 (veja --help)" ;;
  esac
done
URL_BASE="${URL_BASE%/}"
ENDPOINT="$URL_BASE/api/v1/medicoes"

log_init "simular_esp32" "$@"
log_banner "Simulador ESP32 -> $ENDPOINT"

# Gera uma leitura com awk: temperatura, umidade, índice de calor (NOAA/Rothfusz)
# e nível de risco — as mesmas faixas usadas no sketch.ino.
# Saída: "temp umid indice risco"
gerar_leitura() {
  local base="$1" seed="$2" umid_min="${3:-40}"
  awk -v base="$base" -v seed="$seed" -v hmin="$umid_min" 'BEGIN {
    srand(seed);
    t = base + (rand() * 2 - 1);            # variação de ±1 °C
    h = hmin + rand() * 20;                 # umidade entre hmin e hmin+20 %
    f = t * 9 / 5 + 32;
    hi = 0.5 * (f + 61 + (f - 68) * 1.2 + h * 0.094);
    if ((hi + f) / 2 >= 80) {
      hi = -42.379 + 2.04901523*f + 10.14333127*h - 0.22475541*f*h - 0.00683783*f*f \
           - 0.05481717*h*h + 0.00122874*f*f*h + 0.00085282*f*h*h - 0.00000199*f*f*h*h;
    }
    ic = (hi - 32) * 5 / 9;
    if (ic < t) ic = t;
    r = "normal";
    if (ic >= 27) r = "atencao";
    if (ic >= 32) r = "alerta";
    if (ic >= 41) r = "perigo";
    printf "%.1f %.1f %.1f %s\n", t, h, ic, r;
  }'
}

# Monta o JSON exatamente como o sketch.ino (enviarMedicao)
montar_json() {
  local zona="$1" temp="$2" umid="$3" ic="$4" risco="$5" lux="$6" delta="$7" oficial="$8"
  printf '{"device_id":"%s","zona":"%s","temperatura":%s,"umidade":%s,"indice_calor":%s,"luminosidade":%s,"nivel_risco":"%s","delta_ilha_calor":%s,"temperatura_oficial":%s,"timestamp":"%s"}' \
    "$DEVICE_ID" "$zona" "$temp" "$umid" "$ic" "$lux" "$risco" "$delta" "$oficial" "$(date '+%Y-%m-%dT%H:%M:%S%:z')"
}

enviar() {
  local json="$1" resposta codigo
  resposta="$(mktemp)"
  codigo="$(curl -s -o "$resposta" -w '%{http_code}' --max-time 8 -X POST "$ENDPOINT" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $DEVICE_TOKEN" \
    -H "X-Device-Id: $DEVICE_ID" \
    -d "$json" || true)"
  case "$codigo" in
    201)     log_ok "HTTP 201 $(cut -c1-120 "$resposta")" ;;
    401|403) log_warn "HTTP $codigo (dispositivo rejeitado — tentativa registrada na auditoria): $(cat "$resposta")" ;;
    000)     log_error "Sem resposta de $ENDPOINT (API fora do ar?)" ;;
    *)       log_error "HTTP $codigo: $(cat "$resposta")" ;;
  esac
  rm -f "$resposta"
}

main() {
  local i base_arb base_calc umid
  # Cenário de calor: tarde seca de verão (umidade mais baixa, como em Osasco)
  if [[ "$CENARIO" == "calor" ]]; then base_arb=33; base_calc=39; umid=25; else base_arb=27; base_calc=31; umid=45; fi
  for ((i = 1; i <= CICLOS; i++)); do
    log_step "Ciclo $i/$CICLOS"
    local arb calc
    read -r -a arb < <(gerar_leitura "$base_arb" "$((RANDOM + i))" "$umid")
    read -r -a calc < <(gerar_leitura "$base_calc" "$((RANDOM + i * 7))" "$((umid - 10))")
    local delta oficial
    delta="$(awk -v a="${calc[0]}" -v b="${arb[0]}" 'BEGIN {printf "%.1f", a - b}')"
    oficial="$(awk -v a="${arb[0]}" 'BEGIN {printf "%.1f", a + 1.5}')"
    log_info "Arborizada ${arb[0]}°C (${arb[3]}) | Calçadão ${calc[0]}°C (${calc[3]}) | Δ ilha de calor ${delta}°C"
    enviar "$(montar_json arborizada "${arb[0]}" "${arb[1]}" "${arb[2]}" "${arb[3]}" 18000 "$delta" "$oficial")"
    enviar "$(montar_json sem_vegetacao "${calc[0]}" "${calc[1]}" "${calc[2]}" "${calc[3]}" 62000 "$delta" "$oficial")"
    if ((i < CICLOS)); then sleep "$INTERVALO"; fi
  done
  log_info "Veja no navegador: $URL_BASE/  |  resumo: $URL_BASE/api/v1/resumo"
}

main
