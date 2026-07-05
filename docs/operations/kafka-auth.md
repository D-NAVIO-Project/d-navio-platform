# Kafka Authentication (Keycloak / OAUTHBEARER)

## Purpose

This document describes how D-NAVIO Kafka enforces authentication and how
internal services and external partners connect. Kafka uses SASL/OAUTHBEARER:
every client presents a Keycloak-issued OAuth token, which the broker validates
against the `d-navio` realm.

This is **authentication** (who you are), not yet **authorization** (what you may
do). Topic-level ACLs are a planned follow-up; today any valid `d-navio` token is
accepted on every topic.

## Listener Model

The broker exposes four listeners:

| Listener | Bind | Protocol | Exposed | Purpose |
|----------|------|----------|---------|---------|
| `BROKER` | `127.0.0.1:9091` | PLAINTEXT | no (loopback) | inter-broker (broker-to-self) |
| `CONTROLLER` | `127.0.0.1:9093` | PLAINTEXT | no (loopback) | KRaft quorum (single node) |
| `INTERNAL` | `0.0.0.0:9092` | SASL_PLAINTEXT / OAUTHBEARER | `kafka:9092` (ClusterIP) | in-cluster services |
| `EXTERNAL` | `0.0.0.0:9094` | **SASL_SSL** / OAUTHBEARER | `147.102.6.143:30094` (NodePort) | external partners |

The two loopback listeners are PLAINTEXT because they are not a network security
boundary — they only carry the broker talking to itself inside the pod. Every
listener a *client* can reach (`INTERNAL`, `EXTERNAL`) requires a token.

> Encryption note: the **EXTERNAL** listener is `SASL_SSL` — partner tokens are
> encrypted in transit via a TLS server certificate (self-signed dev CA; see
> [keycloak-guide.md](../keycloak-guide.md#tls)). The **INTERNAL** listener stays
> `SASL_PLAINTEXT`: it is only reachable on the trusted in-cluster network, so
> tokens there are authenticated but not encrypted. A production CA-issued
> certificate is a `feat/secrets-management` follow-up.

## Token Flow

```text
Client (service / partner)
   │  1. client_credentials grant (clientId + secret)
   ▼
Keycloak realm d-navio  ──►  returns JWT (iss = pinned hostname, aud = account)
   │  2. SASL/OAUTHBEARER handshake presents the JWT
   ▼
Kafka broker
   │  3. validate signature (JWKS), issuer, audience
   ▼
Access granted / "invalid_token"
```

The broker is configured with:

- `KAFKA_SASL_OAUTHBEARER_JWKS_ENDPOINT_URL` → `http://keycloak:8080/realms/d-navio/protocol/openid-connect/certs` (in-cluster backchannel)
- `KAFKA_SASL_OAUTHBEARER_EXPECTED_ISSUER` → `https://147.102.6.143:30443/realms/d-navio` (the pinned Keycloak hostname)
- `KAFKA_SASL_OAUTHBEARER_EXPECTED_AUDIENCE` → `account` (Keycloak's default audience)

The expected issuer must equal Keycloak's `KC_HOSTNAME` + `/realms/d-navio`. See
[../keycloak-guide.md](../keycloak-guide.md#stable-issuer-important).

## Client Configuration

The listener a client connects to determines the security protocol: the INTERNAL
listener is `SASL_PLAINTEXT`, the EXTERNAL listener is `SASL_SSL`.

### In-cluster service (INTERNAL, SASL_PLAINTEXT)

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=http://keycloak:8080/realms/d-navio/protocol/openid-connect/token
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="<client>" clientSecret="<secret>" ;
```

- `bootstrap.servers=kafka:9092`
- client `dnavio-api`, secret from the `keycloak-client-secrets` Secret

The D-NAVIO Kafka scripts (`scripts/kafka/*.sh`) build exactly this config via
`scripts/kafka/lib.sh`, reading the secret from the cluster.

### External partner, e.g. Maggioli (EXTERNAL, SASL_SSL)

```properties
security.protocol=SASL_SSL
ssl.truststore.type=PEM
ssl.truststore.location=/path/to/dnavio-dev-ca.crt
sasl.mechanism=OAUTHBEARER
sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
sasl.oauthbearer.token.endpoint.url=https://147.102.6.143:30443/realms/d-navio/protocol/openid-connect/token
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="<client>" clientSecret="<secret>" ;
```

- `bootstrap.servers=147.102.6.143:30094`
- their own client + secret (issued during onboarding)
- `ssl.truststore.location` is the environment's dev CA file (distributed
  out-of-band); it lets the client validate the self-signed server certificate.

## Secret Handling

The `dnavio-api` client secret lives only in the `keycloak-client-secrets`
Kubernetes Secret, populated at deploy time via
`--set keycloak.clients.dnavioApi.secret=...` (CI secret). It is:

1. set on the Keycloak client by the `keycloak-realm-bootstrap` Job, and
2. read by the `kafka-topics-init` Job and the scripts to authenticate.

It is never committed to git.

## Partner Onboarding (outline)

1. Create a confidential client for the partner in the `d-navio` realm
   (service-account / client-credentials), issue a client secret.
2. Share with the partner: the HTTPS token endpoint, their `clientId` +
   secret, `bootstrap.servers=147.102.6.143:30094`, the environment's dev CA
   file (for `ssl.truststore.location`), and the topic(s) they may use.
3. Partner builds the EXTERNAL `client.properties` above (SASL_SSL) and connects.
4. (Future) Restrict the partner to specific topics via ACLs.

## Verifying

```bash
# Negative — no token is rejected (times out / invalid_token):
kubectl exec -n dnavio-dev deploy/kafka -- \
  kafka-topics --bootstrap-server kafka:9092 --list      # hangs → denied

# Positive — authenticated list / produce / consume:
./scripts/kafka/list-topics.sh
./scripts/kafka/produce-test-message.sh dnavio.dml.telemetry.raw
./scripts/kafka/consume-topic.sh dnavio.dml.telemetry.raw 1
```

## Troubleshooting

| Symptom (broker log) | Cause | Fix |
|----------------------|-------|-----|
| `Audience (aud) claim [account] present ... no expected audience` | expected audience not set | set `KAFKA_SASL_OAUTHBEARER_EXPECTED_AUDIENCE` |
| `Invalid issuer` / `iss` mismatch | token issuer ≠ broker expected issuer | align `KC_HOSTNAME` with `EXPECTED_ISSUER` |
| `invalid_token` on every connect | client has no/expired token, or wrong realm | check client secret, token endpoint, realm |
| client hangs forever | wrong protocol for the listener | INTERNAL → `SASL_PLAINTEXT`; EXTERNAL → `SASL_SSL` + OAUTHBEARER |
| `SSLHandshakeException` / cert not trusted | missing/wrong truststore on EXTERNAL | point `ssl.truststore.location` at the environment's dev CA file |

## Out of Scope (planned follow-ups)

- Production CA-issued certificate (replacing the self-signed dev CA) — `feat/secrets-management`
- TLS on the INTERNAL listener (currently trusted-network `SASL_PLAINTEXT`)
- Topic-level ACLs / authorization — `feat/rbac-access-model`
- Dedicated `kafka` token audience (tighter than `account`)
