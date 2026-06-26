#!/usr/bin/env bash
# Shared helpers for the D-NAVIO Kafka scripts.
#
# Kafka requires SASL/OAUTHBEARER (Keycloak OIDC) on every client-facing
# listener. These helpers fetch the dnavio-api client secret from the in-cluster
# Secret and build the client.properties the kafka CLIs need.
set -euo pipefail

kafka_ns()        { echo "${DNAVIO_NAMESPACE:-dnavio-dev}"; }
kafka_realm()     { echo "${DNAVIO_REALM:-d-navio}"; }
kafka_client_id() { echo "${DNAVIO_CLIENT_ID:-dnavio-api}"; }

# Read the dnavio-api client secret from the keycloak-client-secrets Secret.
kafka_client_secret() {
  kubectl get secret keycloak-client-secrets -n "$(kafka_ns)" \
    -o jsonpath='{.data.dnavio-api-secret}' | base64 -d
}

# Emit a bash snippet (to run inside the broker pod) that writes
# /tmp/oauth.properties. Arg 1: the client secret.
oauth_properties_block() {
  local secret="$1" realm client
  realm="$(kafka_realm)"
  client="$(kafka_client_id)"
  cat <<EOF
cat > /tmp/oauth.properties <<PROPS
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=http://keycloak:8080/realms/${realm}/protocol/openid-connect/token
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="${client}" clientSecret="${secret}" ;
PROPS
EOF
}
