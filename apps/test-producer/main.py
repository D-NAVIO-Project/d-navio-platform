from fastapi import FastAPI, HTTPException
from kafka import KafkaConsumer, KafkaProducer
import os
import time

app = FastAPI(title="D-NAVIO Test Producer")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "kafka:9092")
TOPIC = os.getenv("KAFKA_TOPIC", "dnavio.telemetry.raw")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/send")
def send():
    try:
        producer = KafkaProducer(
            bootstrap_servers=KAFKA_BOOTSTRAP,
            value_serializer=lambda v: v.encode(),
            request_timeout_ms=5000,
        )
        meta = producer.send(TOPIC, value="42").get(timeout=10)
        producer.close()
        return {
            "sent": "42",
            "topic": TOPIC,
            "partition": meta.partition,
            "offset": meta.offset,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/messages")
def messages(limit: int = 10):
    try:
        consumer = KafkaConsumer(
            TOPIC,
            bootstrap_servers=KAFKA_BOOTSTRAP,
            group_id=f"test-reader-{int(time.time())}",
            auto_offset_reset="earliest",
            consumer_timeout_ms=5000,
            value_deserializer=lambda v: v.decode(),
        )
        result = []
        for msg in consumer:
            result.append({"offset": msg.offset, "value": msg.value})
            if len(result) >= limit:
                break
        consumer.close()
        return {"topic": TOPIC, "messages": result}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
