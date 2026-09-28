#!/bin/sh
# Envia os dashboards e as regras de alerta de UM projeto ao Grafana da plataforma,
# pela API. Idempotente: rodar de novo sobrescreve com o que está no repo do projeto.
#
# Uso:  grafana-sync.sh <dir-provisioning> <uid-da-pasta> "<título da pasta>"
#   <dir-provisioning> no formato de file provisioning do Grafana:
#     dashboards/*.json        um dashboard por arquivo
#     alerting/rules.yml       grupos de regras (`groups:`), opcional
#
# Ambiente:
#   GRAFANA_TOKEN  token de service account do Grafana da plataforma (obrigatório)
#   GRAFANA_URL    default http://localhost:3002
#
# Não envia contact points nem notification policies: são da instância, não do
# projeto (docs/plano-migracao.md §7.1).
#
# Dependências no host: sh, curl, docker (o `yq` roda em container).

set -eu

DIR=${1:?uso: grafana-sync.sh <dir-provisioning> <uid-da-pasta> "<título da pasta>"}
PASTA_UID=${2:?informe o uid da pasta}
PASTA_TITULO=${3:?informe o título da pasta}
URL=${GRAFANA_URL:-http://localhost:3002}
: "${GRAFANA_TOKEN:?defina GRAFANA_TOKEN (service account do Grafana da plataforma)}"

yq() { docker run --rm -i mikefarah/yq "$@"; }

api() {
  metodo=$1 caminho=$2
  shift 2
  resposta=$(curl -sS -w '\n%{http_code}' -X "$metodo" \
    -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Content-Type: application/json' \
    "$@" "$URL$caminho")
  codigo=$(printf '%s' "$resposta" | tail -n 1)
  corpo=$(printf '%s' "$resposta" | sed '$d')
  case $codigo in
    2??) ;;
    *) echo "ERRO $metodo $caminho → HTTP $codigo: $corpo" >&2; return 1 ;;
  esac
}

# Intervalo do grupo ("1m", "30s", "1h") em segundos, como a API espera.
segundos() {
  case $1 in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

# Pasta: cria se não existir.
if ! api GET "/api/folders/$PASTA_UID" -o /dev/null 2>/dev/null; then
  api POST /api/folders -d "{\"uid\":\"$PASTA_UID\",\"title\":\"$PASTA_TITULO\"}" >/dev/null
  echo "pasta criada: $PASTA_TITULO ($PASTA_UID)"
fi

# Dashboards.
for arquivo in "$DIR"/dashboards/*.json; do
  [ -e "$arquivo" ] || continue
  corpo=$(yq -p json -o json -I0 \
    "{\"dashboard\": (. | .id = null), \"folderUid\": \"$PASTA_UID\", \"overwrite\": true, \"message\": \"grafana-sync\"}" \
    < "$arquivo")
  printf '%s' "$corpo" | api POST /api/dashboards/db --data-binary @- >/dev/null
  echo "dashboard: $(basename "$arquivo")"
done

# Regras de alerta. O PUT do grupo só ATUALIZA regras que já existem (o Grafana 11
# responde 500 "could not find alert rule" para uid novo), então cada regra nova é
# criada antes por POST; o PUT em seguida acerta o intervalo e sobrescreve o resto.
regras="$DIR/alerting/rules.yml"
if [ -f "$regras" ]; then
  n=$(yq '.groups | length' < "$regras")
  i=0
  while [ "$i" -lt "$n" ]; do
    grupo=$(yq ".groups[$i].name" < "$regras")
    intervalo=$(segundos "$(yq ".groups[$i].interval" < "$regras")")
    for uid in $(yq ".groups[$i].rules[].uid" < "$regras"); do
      if ! api GET "/api/v1/provisioning/alert-rules/$uid" -o /dev/null 2>/dev/null; then
        yq -o json -I0 \
          ".groups[$i].rules[] | select(.uid == \"$uid\") | . + {\"folderUID\": \"$PASTA_UID\", \"ruleGroup\": \"$grupo\", \"orgID\": 1}" \
          < "$regras" | api POST /api/v1/provisioning/alert-rules --data-binary @- >/dev/null
        echo "regra criada: $uid"
      fi
    done
    corpo=$(yq -o json -I0 \
      ".groups[$i] | {\"title\": .name, \"folderUid\": \"$PASTA_UID\", \"interval\": $intervalo,
        \"rules\": [.rules[] | . + {\"folderUID\": \"$PASTA_UID\", \"ruleGroup\": \"$grupo\", \"orgID\": 1}]}" \
      < "$regras")
    printf '%s' "$corpo" | api PUT "/api/v1/provisioning/folder/$PASTA_UID/rule-groups/$grupo" --data-binary @- >/dev/null
    echo "regras: grupo $grupo ($(yq ".groups[$i].rules | length" < "$regras") regras)"
    i=$((i + 1))
  done
fi
