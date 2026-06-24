#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:?Usage: consume-topic.sh <topic> [max-messages]}"
MAX_MESSAGES="${2:-10}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kafka/lib.sh
source "$DIR/lib.sh"

NS="$(kafka_ns)"
SECRET="$(kafka_client_secret)"

kubectl exec -n "$NS" deploy/kafka -- bash -c "$(oauth_properties_block "$SECRET")
kafka-console-consumer --bootstrap-server kafka:9092 --consumer.config /tmp/oauth.properties --topic '$TOPIC' --from-beginning --max-messages '$MAX_MESSAGES' --timeout-ms 20000"
