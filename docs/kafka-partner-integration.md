# D-NAVIO Kafka Integration Guide for Partners

This guide explains how to connect your application to the D-NAVIO message broker, what you need to request from the NTUA team, and how to deploy your component in Kubernetes with the correct configuration.

---

## 1. What to Request from the NTUA Team

Before writing any code, contact the NTUA team and request the following:

| Item | Description |
|------|-------------|
| **Client ID** | A unique identifier for your application (e.g. `partner-maggioli`) |
| **Client Secret** | A secret credential paired with your Client ID |
| **Topic list** | The specific Kafka topics you are authorized to produce to or consume from |

These credentials are created in D-NAVIO's identity provider (Keycloak) and are specific to your application. Do not share them across teams or applications.

---

## 2. Network Requirements

Before configuring your application, verify that your environment can reach the D-NAVIO platform:

| Endpoint | Host | Port | Protocol | Purpose |
|----------|------|------|----------|---------|
| Kafka broker | `147.102.6.143` | `30094` | TCP | Message produce / consume |
| Token endpoint | `147.102.6.143` | `30080` | HTTP | Obtain OAUTHBEARER token |

**Firewall check** — run these from your environment before writing any code:

```bash
# Check Kafka broker reachability
nc -zv 147.102.6.143 30094

# Check Keycloak reachability
curl -s -o /dev/null -w "%{http_code}" \
  http://147.102.6.143:30080/realms/d-navio/.well-known/openid-configuration
# Expected: 200
```

If either check fails, contact the NTUA team — a firewall rule may need to be opened on their side.

---

## 3. Connection Details

| Parameter | Value |
|-----------|-------|
| **Kafka bootstrap server** | `147.102.6.143:30094` |
| **Security protocol** | `SASL_PLAINTEXT` |
| **SASL mechanism** | `OAUTHBEARER` |
| **Token endpoint** | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token` |

### How authentication works

Your application does **not** send your client secret directly to Kafka. The flow is:

```
Your app  ──(1) POST client_id + client_secret──▶  Keycloak
          ◀──(2) JWT access token (5 min TTL)────
          ──(3) OAUTHBEARER token in handshake──▶  Kafka broker
          ◀──(4) Connection accepted ────────────
```

1. Your app requests a token from Keycloak using the `client_credentials` grant.
2. Keycloak validates and returns a short-lived JWT.
3. Your app presents the JWT as the OAUTHBEARER credential during the Kafka connection handshake.
4. Kafka fetches D-NAVIO's public keys (JWKS) from Keycloak, validates the token signature, issuer, and audience, then accepts or rejects the connection.

Token refresh is handled automatically by the Kafka client libraries shown below.

### Verify token retrieval manually

Before connecting to Kafka, confirm you can obtain a token:

```bash
curl -s -X POST \
  http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token \
  -d "grant_type=client_credentials" \
  -d "client_id=your-client-id" \
  -d "client_secret=your-client-secret" | python3 -m json.tool
```

A successful response looks like:

```json
{
    "access_token": "eyJhbGciOiJSUzI1NiJ9...",
    "expires_in": 300,
    "token_type": "Bearer"
}
```

If you receive a `401` or `invalid_client` error, your credentials are incorrect — contact the NTUA team.

---

## 4. Available Topics

| Topic | Direction | Purpose |
|-------|-----------|---------|
| `dnavio.dml.telemetry.raw` | **Produce** | Raw telemetry data from partner systems |
| `dnavio.dml.telemetry.normalized` | **Consume** | Normalized telemetry processed by D-NAVIO |
| `dnavio.frs.failures.reported` | **Produce / Consume** | Failure reports |
| `dnavio.dml.deadletter` | **Consume** | Messages that could not be processed |

Access to specific topics is granted per client — confirm with the NTUA team which topics your client is authorized to use.

### Message format

Messages are JSON-encoded UTF-8 strings. The expected structure per topic:

**`dnavio.dml.telemetry.raw`**
```json
{
  "source": "partner-maggioli",
  "timestamp": "2026-06-26T12:00:00Z",
  "payload": { }
}
```

**`dnavio.frs.failures.reported`**
```json
{
  "source": "partner-maggioli",
  "timestamp": "2026-06-26T12:00:00Z",
  "failure_type": "sensor_disconnect",
  "details": { }
}
```

Confirm the exact schema with the NTUA team before going live — schemas may evolve.

---

## 5. Deploying in Kubernetes

If your application runs in Kubernetes, store credentials as a Secret and inject them as environment variables.

### Step 1 — Create the Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: dnavio-kafka-credentials
  namespace: your-namespace
type: Opaque
stringData:
  client-id: "your-client-id"
  client-secret: "your-client-secret"
```

```bash
kubectl apply -f dnavio-kafka-credentials.yaml
```

### Step 2 — Reference the Secret in your Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-app
  namespace: your-namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: your-app
  template:
    metadata:
      labels:
        app: your-app
    spec:
      containers:
        - name: your-app
          image: your-image:tag
          env:
            - name: KAFKA_BOOTSTRAP
              value: "147.102.6.143:30094"
            - name: KAFKA_TOKEN_URL
              value: "http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token"
            - name: KAFKA_CLIENT_ID
              valueFrom:
                secretKeyRef:
                  name: dnavio-kafka-credentials
                  key: client-id
            - name: KAFKA_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: dnavio-kafka-credentials
                  key: client-secret
```

### Step 3 — Read the environment variables in your application

```python
import os
BOOTSTRAP     = os.environ["KAFKA_BOOTSTRAP"]
TOKEN_URL     = os.environ["KAFKA_TOKEN_URL"]
CLIENT_ID     = os.environ["KAFKA_CLIENT_ID"]
CLIENT_SECRET = os.environ["KAFKA_CLIENT_SECRET"]
```

---

## 6. Code Examples

### Python

```bash
pip install confluent-kafka requests
```

```python
import os, time, requests
from confluent_kafka import Producer, Consumer

BOOTSTRAP     = os.getenv("KAFKA_BOOTSTRAP",    "147.102.6.143:30094")
TOKEN_URL     = os.getenv("KAFKA_TOKEN_URL",    "http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token")
CLIENT_ID     = os.getenv("KAFKA_CLIENT_ID",    "your-client-id")
CLIENT_SECRET = os.getenv("KAFKA_CLIENT_SECRET","your-client-secret")


def fetch_token(config):
    resp = requests.post(
        TOKEN_URL,
        data={
            "grant_type":    "client_credentials",
            "client_id":     CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        },
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["access_token"], time.time() + data["expires_in"]


kafka_conf = {
    "bootstrap.servers": BOOTSTRAP,
    "security.protocol": "SASL_PLAINTEXT",
    "sasl.mechanism":    "OAUTHBEARER",
    "oauth_cb":          fetch_token,
}


# --- Produce ---
def produce(topic: str, payload: bytes):
    p = Producer(kafka_conf)
    p.produce(topic, value=payload)
    remaining = p.flush(timeout=10)
    if remaining:
        raise RuntimeError("Message not delivered within timeout")


# --- Consume ---
def consume(topic: str, group_id: str):
    c = Consumer({
        **kafka_conf,
        "group.id":          group_id,
        "auto.offset.reset": "earliest",
    })
    c.subscribe([topic])
    try:
        while True:
            msg = c.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                print(f"Consumer error: {msg.error()}")
                continue
            print(f"offset={msg.offset()} value={msg.value().decode()}")
    except KeyboardInterrupt:
        pass
    finally:
        c.close()
```

> **Important:** Use `confluent-kafka`, not `kafka-python`. Only `confluent-kafka` supports OAUTHBEARER.

---

### Java (Spring Boot)

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP:147.102.6.143:30094}
    properties:
      security.protocol: SASL_PLAINTEXT
      sasl.mechanism: OAUTHBEARER
      sasl.login.callback.handler.class: >
        org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
      sasl.oauthbearer.token.endpoint.url: ${KAFKA_TOKEN_URL}
      sasl.jaas.config: >
        org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required
        clientId="${KAFKA_CLIENT_ID}"
        clientSecret="${KAFKA_CLIENT_SECRET}";
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.apache.kafka.common.serialization.StringSerializer
    consumer:
      group-id: your-consumer-group
      auto-offset-reset: earliest
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.apache.kafka.common.serialization.StringDeserializer
```

---

## 7. Error Handling

| Error | Likely Cause | Action |
|-------|-------------|--------|
| `Connection refused` to port 30094 | Network/firewall | Check port reachability with `nc -zv` |
| `401 Unauthorized` from token endpoint | Wrong `client_id` or `client_secret` | Verify credentials with the NTUA team |
| `Authentication failed` from Kafka | Token expired or wrong issuer | Check the token endpoint URL — must match exactly |
| `Topic authorization failed` | Client not authorized for this topic | Request access from the NTUA team |
| `Leader not available` | Kafka is starting up | Retry with backoff — Kafka takes ~30s to be ready |

### Recommended retry configuration (Python)

```python
kafka_conf = {
    ...
    "retries":                    5,
    "retry.backoff.ms":           500,
    "socket.timeout.ms":          10000,
    "message.timeout.ms":         30000,
}
```

---

## 8. Consumer Group Best Practices

- Use a **unique group ID per application** — e.g. `partner-maggioli-telemetry-consumer`. Sharing a group ID across unrelated applications causes unexpected load balancing.
- Use `auto.offset.reset: earliest` on first deploy to read all existing messages. Switch to `latest` once caught up if you only need new messages.
- **Do not set `enable.auto.commit: false`** unless you are implementing manual offset management — the default auto-commit is sufficient for most use cases.
- If your consumer restarts frequently, increase `session.timeout.ms` (default 45s) to prevent unnecessary partition rebalancing.

---

## 9. Notes and Constraints

- **No TLS** — the connection uses `SASL_PLAINTEXT` (authenticated but unencrypted). If your compliance requirements mandate encryption in transit, raise this with the NTUA team.
- **Token TTL is 5 minutes** — the client libraries handle refresh automatically. Do not cache tokens manually.
- **One client per application** — do not share `client_id` / `client_secret` across teams or services.
- **Topic access is scoped** — your client is only granted access to agreed topics. Unauthorized topic access returns an authentication error, not a permissions error.

---

## 10. Onboarding Checklist

- [ ] Client ID and Client Secret received from the NTUA team
- [ ] Topics confirmed with the NTUA team
- [ ] Port `30094` (Kafka) reachable from your environment
- [ ] Port `30080` (Keycloak) reachable from your environment
- [ ] Token obtained successfully via `curl`
- [ ] Test message produced and consumed end-to-end
- [ ] Kubernetes Secret created and injected into your Deployment
- [ ] Consumer group ID follows the naming convention `partner-<name>-<purpose>`

---

*For access requests or integration support, contact the NTUA team.*
