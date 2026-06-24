#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://147.102.6.143:30080}"
REALM="${DNAVIO_REALM:-d-navio}"
CLIENT_ID="${DNAVIO_CLIENT_ID:-dnavio-api}"
CLIENT_SECRET="${DNAVIO_CLIENT_SECRET:?DNAVIO_CLIENT_SECRET is required}"

curl -s -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}"
