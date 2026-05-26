#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:?Usage: produce-test-message.sh <topic>}"
NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MESSAGE="{\"event_type\":\"sensor_update\",\"timestamp\":\"${TIMESTAMP}\",\"ship_id\":\"ship_001\",\"component_id\":\"pump_01\",\"sensor_id\":\"temp_01\",\"value\":82.4,\"unit\":\"C\"}"

echo "$MESSAGE" | kubectl exec -i -n "$NAMESPACE" deploy/kafka -- \
  kafka-console-producer --bootstrap-server kafka:9092 --topic "$TOPIC"

echo "Message sent to topic: $TOPIC"
