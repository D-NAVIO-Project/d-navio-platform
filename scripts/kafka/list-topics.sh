#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/kafka/lib.sh
source "$DIR/lib.sh"

NS="$(kafka_ns)"
SECRET="$(kafka_client_secret)"

kubectl exec -n "$NS" deploy/kafka -- bash -c "$(oauth_properties_block "$SECRET")
kafka-topics --bootstrap-server kafka:9092 --command-config /tmp/oauth.properties --list"
