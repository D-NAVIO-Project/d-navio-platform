#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${DNAVIO_NAMESPACE:-dnavio-dev}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://147.102.6.143:30080}"
REALM="${DNAVIO_REALM:-d-navio}"

echo "--- Keycloak pod status ---"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=keycloak

echo ""
echo "--- Realm check: ${REALM} ---"
if curl -sf "${KEYCLOAK_URL}/realms/${REALM}" > /dev/null; then
  echo "[OK] Realm '${REALM}' exists"
else
  echo "[WARN] Realm '${REALM}' not found — create it in the admin console"
fi
