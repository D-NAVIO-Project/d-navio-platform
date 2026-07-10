from fastapi import FastAPI, HTTPException
from confluent_kafka import Consumer, Producer
import os
import time
import requests

app = FastAPI(title="D-NAVIO Test Producer")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "dnavio.telemetry.raw")
KEYCLOAK_URL = os.getenv("KEYCLOAK_URL", "http://keycloak:8080")
KEYCLOAK_REALM = os.getenv("KEYCLOAK_REALM", "d-navio")
CLIENT_ID = os.getenv("KEYCLOAK_CLIENT_ID", "dnavio-api")
CLIENT_SECRET = os.getenv("KEYCLOAK_CLIENT_SECRET", "")


def _fetch_token(config):
    """OAUTHBEARER callback — called by confluent-kafka before each connection."""
    resp = requests.post(
        f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token",
        data={
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        },
        timeout=10,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["access_token"], time.time() + data["expires_in"]


def _kafka_conf() -> dict:
    return {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": _fetch_token,
    }


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/send")
def send():
    # flush() alone is not enough: a rejected message (e.g. authorization
    # failure) still fires a delivery report and empties the queue — the error
    # is only visible through the delivery callback.
    delivery = {}

    def _on_delivery(err, _msg):
        delivery["error"] = err

    try:
        p = Producer(_kafka_conf())
        p.produce(TOPIC, value=b"42", on_delivery=_on_delivery)
        remaining = p.flush(timeout=10)
        if remaining:
            raise RuntimeError("Message not delivered within timeout")
        if delivery.get("error") is not None:
            raise RuntimeError(f"Delivery failed: {delivery['error']}")
        return {"sent": "42", "topic": TOPIC}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/messages")
def messages(limit: int = 10):
    try:
        conf = _kafka_conf()
        conf.update({
            "group.id": f"test-reader-{int(time.time())}",
            "auto.offset.reset": "earliest",
        })
        c = Consumer(conf)
        c.subscribe([TOPIC])
        result = []
        deadline = time.time() + 10
        while len(result) < limit and time.time() < deadline:
            msg = c.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                break
            result.append({"offset": msg.offset(), "value": msg.value().decode()})
        c.close()
        return {"topic": TOPIC, "messages": result}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
