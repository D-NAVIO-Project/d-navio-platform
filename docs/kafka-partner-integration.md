# D-NAVIO Kafka Integration Guide for Partners

This guide explains how to connect your application to the D-NAVIO message broker and what you need to request from the D-NAVIO team before getting started.

---

## 1. What to Request from D-NAVIO

Before writing any code, contact the D-NAVIO team and request the following:

| Item | Description |
|------|-------------|
| **Client ID** | A unique identifier for your application (e.g. `partner-maggioli`) |
| **Client Secret** | A secret credential paired with your Client ID |
| **Topic list** | The specific Kafka topics you are authorized to produce to or consume from |

These credentials are created in D-NAVIO's identity provider (Keycloak) and are specific to your application. Do not share them.

---

## 2. Connection Details

Once you have your credentials, use the following to connect:

| Parameter | Value |
|-----------|-------|
| **Kafka bootstrap server** | `147.102.6.143:30094` |
| **Security protocol** | `SASL_PLAINTEXT` |
| **SASL mechanism** | `OAUTHBEARER` |
| **Token endpoint** | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token` |

### How authentication works

Your application does **not** send your client secret directly to Kafka. Instead:

1. Your app calls the D-NAVIO token endpoint with your `client_id` and `client_secret`.
2. Keycloak (D-NAVIO's identity provider) validates them and returns a short-lived JWT token.
3. Your app presents that token to Kafka as the OAUTHBEARER credential.
4. Kafka validates the token's signature and grants access.

Tokens expire (default: 5 minutes). The libraries below handle refresh automatically — you do not need to manage this manually.

---

## 3. Available Topics

| Topic | Purpose |
|-------|---------|
| `dnavio.dml.telemetry.raw` | Raw telemetry data ingestion |
| `dnavio.dml.telemetry.normalized` | Normalized/processed telemetry |
| `dnavio.frs.failures.reported` | Failure reports |
| `dnavio.dml.deadletter` | Unprocessable messages |

Access to specific topics is granted per client. Confirm with the D-NAVIO team which topics your client is authorized to use.

---

## 4. Code Examples

### Python

Install the required library:

```bash
pip install confluent-kafka requests
```

```python
import time
import requests
from confluent_kafka import Producer, Consumer

# Credentials provided by D-NAVIO
BOOTSTRAP     = "147.102.6.143:30094"
TOKEN_URL     = "http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token"
CLIENT_ID     = "your-client-id"
CLIENT_SECRET = "your-client-secret"


def fetch_token(config):
    """Called automatically by the library to obtain or refresh the bearer token."""
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


# --- Produce a message ---
producer = Producer(kafka_conf)
producer.produce("dnavio.dml.telemetry.raw", value=b"your-payload")
producer.flush()
print("Message sent.")


# --- Consume messages ---
consumer = Consumer({
    **kafka_conf,
    "group.id":          "your-consumer-group",
    "auto.offset.reset": "earliest",
})
consumer.subscribe(["dnavio.dml.telemetry.raw"])

try:
    while True:
        msg = consumer.poll(timeout=1.0)
        if msg is None:
            continue
        if msg.error():
            print(f"Error: {msg.error()}")
            continue
        print(f"Received: offset={msg.offset()} value={msg.value()}")
finally:
    consumer.close()
```

> **Important:** Use `confluent-kafka`, not `kafka-python`. Only `confluent-kafka` supports the OAUTHBEARER mechanism required by D-NAVIO.

---

### Java

Add the Kafka client dependency (Maven):

```xml
<dependency>
    <groupId>org.apache.kafka</groupId>
    <artifactId>kafka-clients</artifactId>
    <version>3.9.0</version>
</dependency>
```

```java
import org.apache.kafka.clients.producer.*;
import java.util.Properties;

public class DNavioProducerExample {
    public static void main(String[] args) throws Exception {
        Properties props = new Properties();

        // Connection
        props.put("bootstrap.servers", "147.102.6.143:30094");

        // Authentication
        props.put("security.protocol", "SASL_PLAINTEXT");
        props.put("sasl.mechanism",    "OAUTHBEARER");
        props.put("sasl.login.callback.handler.class",
            "org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler");
        props.put("sasl.oauthbearer.token.endpoint.url",
            "http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token");
        props.put("sasl.jaas.config",
            "org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required " +
            "clientId=\"your-client-id\" " +
            "clientSecret=\"your-client-secret\";");

        // Serializers
        props.put("key.serializer",   "org.apache.kafka.common.serialization.StringSerializer");
        props.put("value.serializer", "org.apache.kafka.common.serialization.ByteArraySerializer");

        try (KafkaProducer<String, byte[]> producer = new KafkaProducer<>(props)) {
            ProducerRecord<String, byte[]> record =
                new ProducerRecord<>("dnavio.dml.telemetry.raw", "your-payload".getBytes());
            producer.send(record).get();
            System.out.println("Message sent.");
        }
    }
}
```

---

## 5. Notes and Constraints

- **No TLS in the current setup** — the connection uses `SASL_PLAINTEXT` (authenticated but not encrypted). If your compliance requirements mandate encryption in transit, raise this with the D-NAVIO team.
- **Token expiry** — tokens are short-lived. Both library examples above handle automatic refresh; no manual renewal is needed.
- **One client per application** — do not reuse the same `client_id` / `client_secret` across multiple applications or teams.
- **Topic access is scoped** — your client is granted access only to the topics agreed with D-NAVIO. Attempting to produce or consume from unauthorized topics will result in an authentication error.

---

## 6. Onboarding Checklist

Before going live, confirm the following with the D-NAVIO team:

- [ ] Client ID and Client Secret received
- [ ] Topics you need access to have been confirmed
- [ ] You have tested connectivity to `147.102.6.143:30094` from your network
- [ ] You have successfully obtained a token from the token endpoint
- [ ] A test message has been produced and consumed end-to-end

---

*For questions or access requests, contact the D-NAVIO platform team.*
