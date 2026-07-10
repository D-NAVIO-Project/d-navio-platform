"""D-NAVIO mock partner service.

Simulates an external partner integrating with the D-NAVIO platform by the
book: it connects exclusively through the public endpoints (Kafka external
SASL_SSL listener + HTTPS token endpoint), authenticates with its own
service-account identity, and verifies TLS against the D-NAVIO dev CA.
It deliberately follows docs/kafka-partner-integration.md so it also serves
as a living validation of that guide.
"""
import json
import os
import time
import uuid
from datetime import datetime, timezone

import requests
from confluent_kafka import Consumer, Producer
from fastapi import FastAPI, HTTPException

app = FastAPI(title="D-NAVIO Mock Partner")

BOOTSTRAP     = os.getenv("KAFKA_BOOTSTRAP", "147.102.6.143:30094")
TOKEN_URL     = os.getenv("KAFKA_TOKEN_URL", "https://147.102.6.143:30443/realms/d-navio/protocol/openid-connect/token")
CLIENT_ID     = os.getenv("KAFKA_CLIENT_ID", "svc-dynamo")
CLIENT_SECRET = os.getenv("KAFKA_CLIENT_SECRET", "")
CA_CERT       = os.getenv("KAFKA_CA_CERT", "/etc/dnavio-ca/ca.crt")
TOPIC         = os.getenv("KAFKA_TOPIC", "dnavio.dml.telemetry.raw")


def _fetch_token(config):
    """oauth_cb: obtain (and later refresh) the OAUTHBEARER token."""
    resp = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "client_credentials",
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
        },
        timeout=10,
        verify=CA_CERT,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["access_token"], time.time() + data["expires_in"]


def _kafka_conf() -> dict:
    return {
        "bootstrap.servers": BOOTSTRAP,
        "security.protocol": "SASL_SSL",
        "ssl.ca.location": CA_CERT,
        "sasl.mechanism": "OAUTHBEARER",
        "oauth_cb": _fetch_token,
    }


@app.get("/health")
def health():
    return {"status": "ok", "identity": CLIENT_ID, "bootstrap": BOOTSTRAP}


@app.get("/token-check")
def token_check():
    """Verify the auth chain up to Keycloak without touching Kafka."""
    try:
        token, expires_at = _fetch_token(None)
        # Do not return the token itself — just proof we obtained one.
        return {
            "token_obtained": True,
            "identity": CLIENT_ID,
            "expires_in_seconds": round(expires_at - time.time()),
        }
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@app.post("/send")
def send():
    """Produce one telemetry message shaped per the partner guide schema."""
    message = {
        "source": CLIENT_ID,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "payload": {"reading_id": str(uuid.uuid4()), "value": 42},
    }
    try:
        p = Producer(_kafka_conf())
        p.produce(TOPIC, value=json.dumps(message).encode())
        remaining = p.flush(timeout=15)
        if remaining:
            raise RuntimeError("Message not delivered within timeout")
        return {"sent": message, "topic": TOPIC}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@app.get("/messages")
def messages(limit: int = 10):
    """Consume up to `limit` messages from the beginning of the topic."""
    try:
        c = Consumer({
            **_kafka_conf(),
            "group.id": f"{CLIENT_ID}-mock-reader",
            "auto.offset.reset": "earliest",
        })
        c.subscribe([TOPIC])
        out = []
        deadline = time.time() + 10
        while len(out) < limit and time.time() < deadline:
            msg = c.poll(timeout=1.0)
            if msg is None:
                continue
            if msg.error():
                continue
            out.append({
                "offset": msg.offset(),
                "value": msg.value().decode(errors="replace"),
            })
        c.close()
        return {"topic": TOPIC, "messages": out}
    except Exception as exc:
        raise HTTPException(status_code=502, detail=str(exc))
