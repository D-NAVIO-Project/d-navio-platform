#!/usr/bin/env bash
set -euo pipefail

# Defaults to the HTTPS endpoint. Because the dev certificate is self-signed,
# set KEYCLOAK_CACERT to the environment's CA file (e.g. dnavio-dev-ca.crt,
# produced by scripts/tls/generate-dev-cert.sh) so curl can validate the server.
KEYCLOAK_URL="${KEYCLOAK_URL:-https://147.102.6.143:30443}"
KEYCLOAK_CACERT="${KEYCLOAK_CACERT:-}"
REALM="${DNAVIO_REALM:-d-navio}"
CLIENT_ID="${DNAVIO_CLIENT_ID:-dnavio-api}"
CLIENT_SECRET="${DNAVIO_CLIENT_SECRET:?DNAVIO_CLIENT_SECRET is required}"

CURL_OPTS=()
if [ -n "${KEYCLOAK_CACERT}" ]; then
  CURL_OPTS+=(--cacert "${KEYCLOAK_CACERT}")
fi

curl -s "${CURL_OPTS[@]}" -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${CLIENT_ID}" \
  -d "client_secret=${CLIENT_SECRET}"
