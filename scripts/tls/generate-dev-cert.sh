#!/usr/bin/env bash
# Generate a self-signed dev CA + server certificate for D-NAVIO TLS (Keycloak
# HTTPS + Kafka SASL_SSL external listener), and store the server cert/key as a
# standard kubernetes.io/tls Secret (keys: tls.crt, tls.key) in the target
# namespace.
#
# Each run generates a NEW CA and server certificate — nothing is reused across
# namespaces. Run this once per namespace before deploying there; dev,
# integration, and pilot each get their own independent dev CA.
#
# This is a self-signed dev CA — not suitable for production use.
#
# Usage: generate-dev-cert.sh [namespace] [advertised-host] [secret-name]
set -euo pipefail

for cmd in openssl kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not found in PATH." >&2
    exit 1
  fi
done

NAMESPACE="${1:-dnavio-dev}"
HOST="${2:-147.102.6.143}"
SECRET_NAME="${3:-dnavio-tls}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cat > "$WORKDIR/san.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${HOST}
[v3_req]
subjectAltName = @alt_names
[alt_names]
IP.1 = ${HOST}
EOF

echo "Generating a new self-signed dev CA for namespace '${NAMESPACE}'..."
openssl genrsa -out "$WORKDIR/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$WORKDIR/ca.key" -sha256 -days 3650 \
  -out "$WORKDIR/ca.crt" -subj "/CN=D-NAVIO Dev CA (${NAMESPACE})" 2>/dev/null

echo "Generating server certificate for ${HOST}, signed by this CA..."
openssl genrsa -out "$WORKDIR/server.key" 2048 2>/dev/null
openssl req -new -key "$WORKDIR/server.key" -out "$WORKDIR/server.csr" \
  -config "$WORKDIR/san.cnf" 2>/dev/null
openssl x509 -req -in "$WORKDIR/server.csr" \
  -CA "$WORKDIR/ca.crt" -CAkey "$WORKDIR/ca.key" -CAcreateserial \
  -out "$WORKDIR/server.crt" -days 825 -sha256 \
  -extensions v3_req -extfile "$WORKDIR/san.cnf" 2>/dev/null

# kubernetes.io/tls Secrets store exactly two keys: tls.crt and tls.key (the
# server certificate + private key). The CA certificate is not part of this
# Secret — it must be distributed separately to any client that needs to
# validate the server certificate (see output below).
echo "Creating Secret '${SECRET_NAME}' (kubernetes.io/tls) in namespace '${NAMESPACE}'..."
kubectl create secret tls "$SECRET_NAME" \
  --cert="$WORKDIR/server.crt" --key="$WORKDIR/server.key" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

CA_OUT="./${NAMESPACE}-ca.crt"
cp "$WORKDIR/ca.crt" "$CA_OUT"
echo ""
echo "Done. Server cert/key stored in Secret '${SECRET_NAME}' (namespace ${NAMESPACE})."
echo "This CA is specific to '${NAMESPACE}' — dev/integration/pilot each have their own."
echo "CA certificate saved locally to ${CA_OUT}. Distribute this file (not the"
echo "private key, which never leaves this script's temp workdir) to any client"
echo "— including external partners — that needs to validate the server certificate"
echo "for this environment."
