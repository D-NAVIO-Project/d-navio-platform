#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"
BOOTSTRAP="kafka:9092"

TOPICS=(
  dnavio.telemetry.raw
  dnavio.telemetry.processed
  dnavio.alerts
  dnavio.failures
  dnavio.risk
)

for topic in "${TOPICS[@]}"; do
  kubectl exec -n "$NAMESPACE" deploy/kafka -- \
    kafka-topics --bootstrap-server "$BOOTSTRAP" \
      --create --topic "$topic" \
      --partitions 1 --replication-factor 1 \
      --if-not-exists
done

echo "All D-NAVIO topics created in namespace: $NAMESPACE"
