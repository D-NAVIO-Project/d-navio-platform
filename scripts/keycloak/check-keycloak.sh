#!/usr/bin/env bash
set -euo pipefail

# Defaults to the HTTPS endpoint. For the self-signed dev cert, set
# KEYCLOAK_CACERT to the environment's CA file so curl can validate the server.
NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://147.102.6.143:30443}"
KEYCLOAK_CACERT="${KEYCLOAK_CACERT:-}"
REALM="${DNAVIO_REALM:-d-navio}"

CURL_OPTS=()
if [ -n "${KEYCLOAK_CACERT}" ]; then
  CURL_OPTS+=(--cacert "${KEYCLOAK_CACERT}")
fi

echo "--- Keycloak pod status ---"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=keycloak

echo ""
echo "--- Realm check: ${REALM} ---"
if curl -sf "${CURL_OPTS[@]}" "${KEYCLOAK_URL}/realms/${REALM}" > /dev/null; then
  echo "[OK] Realm '${REALM}' exists"
else
  echo "[WARN] Realm '${REALM}' not reachable (check URL / KEYCLOAK_CACERT / realm)"
fi
