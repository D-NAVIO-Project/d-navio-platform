#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:?Usage: consume-topic.sh <topic> [max-messages]}"
MAX_MESSAGES="${2:-10}"
NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"

kubectl exec -n "$NAMESPACE" deploy/kafka -- \
  kafka-console-consumer --bootstrap-server kafka:9092 \
    --topic "$TOPIC" \
    --from-beginning \
    --max-messages "$MAX_MESSAGES" \
    --timeout-ms 20000
