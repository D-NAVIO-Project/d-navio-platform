#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:?Usage: produce-test-message.sh <topic>}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kafka/lib.sh
source "$DIR/lib.sh"

NS="$(kafka_ns)"
SECRET="$(kafka_client_secret)"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MESSAGE="{\"event_type\":\"sensor_update\",\"timestamp\":\"${TIMESTAMP}\",\"ship_id\":\"ship_001\",\"component_id\":\"pump_01\",\"sensor_id\":\"temp_01\",\"value\":82.4,\"unit\":\"C\"}"

echo "$MESSAGE" | kubectl exec -i -n "$NS" deploy/kafka -- bash -c "$(oauth_properties_block "$SECRET")
kafka-console-producer --bootstrap-server kafka:9092 --producer.config /tmp/oauth.properties --topic '$TOPIC'"

echo "Message sent to topic: $TOPIC"
