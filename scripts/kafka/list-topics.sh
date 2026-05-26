#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"

kubectl exec -n "$NAMESPACE" deploy/kafka -- \
  kafka-topics --bootstrap-server kafka:9092 --list
