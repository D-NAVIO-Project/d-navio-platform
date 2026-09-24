// D-NAVIO T4.2 — shared document store
//
// D4.1 §6.1.2 pairs the relational store with a document store for "long-term storage and
// retrieval of data and component outputs", and notes that "the precise division of
// responsibility between the document and relational stores will be determined as data
// requirements are consolidated". D2.3 §5.4 gives the working split this repository follows:
// PostgreSQL for schema-compliant structured records amenable to statistical query, MongoDB
// for "unstructured or semi-structured log data, raw sensor streams, and flexible incident
// metadata".
//
// So: everything queried numerically lives in Postgres; everything kept for traceability,
// lineage and post-event analysis lives here, in the shape it arrived in.

const db = db.getSiblingDB('dnavio');

// Raw event envelopes exactly as accepted, before normalisation. This is what makes an
// ingestion decision auditable after the fact: if a metric mapping is later found wrong,
// the original payload is still here to re-derive from.
db.createCollection('iot_raw_event');
db.iot_raw_event.createIndex({ 'envelope.event_id': 1 }, { unique: true });
db.iot_raw_event.createIndex({ 'payload.vessel_id': 1, 'payload.observed_at': -1 });
db.iot_raw_event.createIndex({ 'payload.metric': 1, 'payload.observed_at': -1 });
db.iot_raw_event.createIndex({ 'envelope.correlation_id': 1 });

// Evidence behind a failure record: the contributing observation window, the values that
// crossed the threshold, and any unstructured context. Kept separate from the Postgres
// projection because episode evidence is variable-shaped and can be large.
db.createCollection('failure_evidence');
db.failure_evidence.createIndex({ report_id: 1 }, { unique: true });
db.failure_evidence.createIndex({ vessel_id: 1, detected_at: -1 });
db.failure_evidence.createIndex({ rule_id: 1 });

// Flexible incident metadata. The landing zone for material that has no fixed schema:
// narrative incident reports, class/survey documents, maintenance records, FMEA extracts.
// Empty today — neither pilot was able to supply historical failure records (COLUMBIA:
// "no historical failure records are available for this specific application"; DANAOS
// holds only arbitrary third-party incidents, shared with DMC).
db.createCollection('incident_metadata');
db.incident_metadata.createIndex({ vessel_id: 1, occurred_at: -1 });
db.incident_metadata.createIndex({ source: 1 });
db.incident_metadata.createIndex({ tags: 1 });

// Dead-lettered messages, retained for diagnosis alongside the Kafka DLQ topic. The topic
// expires after 30 days; this does not.
db.createCollection('deadletter');
db.deadletter.createIndex({ failed_at: -1 });
db.deadletter.createIndex({ source_topic: 1, failed_at: -1 });

print('dnavio: document store initialised');
