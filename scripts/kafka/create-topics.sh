#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kafka/lib.sh
source "$DIR/lib.sh"

NS="$(kafka_ns)"
SECRET="$(kafka_client_secret)"

TOPICS=(
  dnavio.dml.telemetry.raw
  dnavio.dml.telemetry.normalized
  dnavio.frs.failures.reported
  dnavio.dml.deadletter
)

CMDS=""
for topic in "${TOPICS[@]}"; do
  CMDS+="kafka-topics --bootstrap-server kafka:9092 --command-config /tmp/oauth.properties --create --topic ${topic} --partitions 1 --replication-factor 1 --if-not-exists
"
done

kubectl exec -n "$NS" deploy/kafka -- bash -c "$(oauth_properties_block "$SECRET")
${CMDS}"

echo "All D-NAVIO topics created in namespace: $NS"
