#!/usr/bin/env python3
"""Smoke test: validates Keycloak and Kafka connectivity from inside the cluster.

Run inside the target namespace:
    kubectl apply -f test/smoke-test.yaml -n dnavio-dev
    kubectl logs -n dnavio-dev -l job-name=platform-smoke-test --follow
"""

import json
import sys
import time
import uuid

import requests
from kafka import KafkaConsumer, KafkaProducer

KEYCLOAK_URL = "http://keycloak:8080"
KAFKA_BOOTSTRAP = "kafka:9092"
TEST_TOPIC = "dnavio.telemetry.raw"
CONSUME_TIMEOUT_S = 30

results: dict[str, str] = {}


# ── Keycloak ──────────────────────────────────────────────────────────────────

print("=== Keycloak ===")

try:
    r = requests.get(f"{KEYCLOAK_URL}/health/live", timeout=10)
    r.raise_for_status()
    results["keycloak_health"] = "PASS"
    print(f"[PASS] /health/live → {r.status_code}")
except Exception as exc:
    results["keycloak_health"] = f"FAIL: {exc}"
    print(f"[FAIL] /health/live → {exc}")

try:
    r = requests.get(
        f"{KEYCLOAK_URL}/realms/master/.well-known/openid-configuration",
        timeout=10,
    )
    r.raise_for_status()
    issuer = r.json().get("issuer", "?")
    results["keycloak_oidc"] = "PASS"
    print(f"[PASS] OIDC discovery → issuer={issuer}")
except Exception as exc:
    results["keycloak_oidc"] = f"FAIL: {exc}"
    print(f"[FAIL] OIDC discovery → {exc}")


# ── Kafka ─────────────────────────────────────────────────────────────────────

print("\n=== Kafka ===")

test_id = str(uuid.uuid4())
payload = json.dumps({"smoke_test": True, "id": test_id})

try:
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        value_serializer=lambda v: v.encode("utf-8"),
        request_timeout_ms=10_000,
    )
    meta = producer.send(TEST_TOPIC, value=payload).get(timeout=15)
    producer.close()
    results["kafka_produce"] = "PASS"
    print(f"[PASS] Produced to {TEST_TOPIC} partition={meta.partition} offset={meta.offset}")
except Exception as exc:
    results["kafka_produce"] = f"FAIL: {exc}"
    print(f"[FAIL] Produce → {exc}")

if results.get("kafka_produce") == "PASS":
    try:
        consumer = KafkaConsumer(
            TEST_TOPIC,
            bootstrap_servers=KAFKA_BOOTSTRAP,
            group_id=f"smoke-test-{test_id}",
            auto_offset_reset="earliest",
            consumer_timeout_ms=CONSUME_TIMEOUT_S * 1_000,
            value_deserializer=lambda v: v.decode("utf-8"),
        )
        found = False
        deadline = time.time() + CONSUME_TIMEOUT_S
        for msg in consumer:
            if test_id in msg.value:
                found = True
                break
            if time.time() > deadline:
                break
        consumer.close()
        if found:
            results["kafka_consume"] = "PASS"
            print(f"[PASS] Consumed test message back from {TEST_TOPIC}")
        else:
            results["kafka_consume"] = f"FAIL: message not seen within {CONSUME_TIMEOUT_S}s"
            print(f"[FAIL] Message not seen within {CONSUME_TIMEOUT_S}s")
    except Exception as exc:
        results["kafka_consume"] = f"FAIL: {exc}"
        print(f"[FAIL] Consume → {exc}")


# ── Summary ───────────────────────────────────────────────────────────────────

print("\n=== Summary ===")
all_pass = True
for check, result in results.items():
    marker = "PASS" if result == "PASS" else "FAIL"
    if marker == "FAIL":
        all_pass = False
    print(f"  {check}: {result}")

if all_pass:
    print("\nAll checks passed.")
    sys.exit(0)
else:
    print("\nOne or more checks failed.")
    sys.exit(1)
