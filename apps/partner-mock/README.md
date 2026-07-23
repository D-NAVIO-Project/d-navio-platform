# Mock Partner Service

Simulates an external partner integrating with D-NAVIO **by the book**: it
authenticates as its own service-account identity (`svc-dynamo`, the designated
MAG-environment identity from `docs/operations/rbac-access-model.md`), fetches
tokens from the **HTTPS** token endpoint, connects to the Kafka **external
SASL_SSL** listener at the public address, and verifies TLS against the
environment's dev CA. It never uses in-cluster shortcuts, so a successful run
proves the exact path a real partner will take — and validates
`docs/kafka-partner-integration.md` end to end.

## Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /health` | Liveness + which identity is configured |
| `GET /token-check` | Proves Keycloak auth works (no Kafka involved) |
| `POST /send` | Produces one schema-shaped telemetry message |
| `GET /messages` | Consumes messages back from the topic |

## Deployment (on the platform VM)

Prerequisite: the platform is deployed from a branch that includes TLS + RBAC
(bootstrap has created `svc-dynamo`, the `dnavio-tls` Secret exists, and
`dnavio-dev-ca.crt` was saved by `scripts/tls/generate-dev-cert.sh`).

### 1. Retrieve the svc-dynamo client secret from Keycloak

The bootstrap Job creates `svc-dynamo` without a fixed secret — Keycloak
generates one. Retrieve it (run as-is; it reads the admin credentials from the
pod's own environment):

```bash
KC_POD=$(kubectl get pod -n dnavio-dev -l app.kubernetes.io/component=keycloak -o name | head -1)
kubectl exec -n dnavio-dev "$KC_POD" -- bash -c '
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r d-navio -q clientId=svc-dynamo \
    --fields id --format csv --noquotes | tail -n1)
  /opt/keycloak/bin/kcadm.sh get "clients/${CID}/client-secret" -r d-navio
'
```

The `value` field in the JSON output is the client secret.

### 2. Create the namespace and secrets

```bash
kubectl create namespace partner-mock

kubectl create secret generic dnavio-kafka-credentials -n partner-mock \
  --from-literal=client-id=svc-dynamo \
  --from-literal=client-secret=<value-from-step-1>

# CA file was left in the directory where generate-dev-cert.sh was run
kubectl create secret generic dnavio-ca -n partner-mock \
  --from-file=ca.crt=dnavio-dev-ca.crt
```

### 3. Build the image and import it into containerd

```bash
docker build -t partner-mock:latest apps/partner-mock/
docker save partner-mock:latest | sudo ctr -n k8s.io images import -
```

### 4. Deploy

```bash
kubectl apply -f apps/partner-mock/k8s/partner-mock.yaml
kubectl rollout status deployment/partner-mock -n partner-mock --timeout=2m
```

## Validation sequence

```bash
# 1. App is up
curl http://147.102.6.143:30800/health

# 2. Keycloak auth chain works (HTTPS + CA verification + client credentials)
curl http://147.102.6.143:30800/token-check

# 3. Full produce path: token -> SASL_SSL handshake -> broker accepts -> message stored
curl -X POST http://147.102.6.143:30800/send

# 4. Full consume path
curl http://147.102.6.143:30800/messages
```

If all four succeed, the complete external partner path is proven:
credential issuance, HTTPS token retrieval, TLS-verified SASL_SSL connection,
OAUTHBEARER validation at the broker, and produce/consume on the shared topic.
