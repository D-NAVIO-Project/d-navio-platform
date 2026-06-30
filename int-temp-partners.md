# D-NAVIO Kafka Integration Guide for Partners

This guide explains how to connect your application to the D-NAVIO message broker and what you need to request from the D-NAVIO team before getting started.


## 1. What to Request from D-NAVIO

Before writing any code, contact the D-NAVIO team and request the following:

| Item | Description |
|------|-------------|
| **Client ID** | A unique identifier for your application (e.g. `partner-maggioli`) |
| **Client Secret** | A secret credential paired with your Client ID |
| **Topic list** | The specific Kafka topics you are authorized to produce to or consume from |

These credentials are created in D-NAVIO's identity provider (Keycloak) and are specific to your application. Do not share them.


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


## 3. Available Topics

| Topic | Purpose |
|-------|---------|
| `dnavio.dml.telemetry.raw` | Raw telemetry data ingestion |
| `dnavio.dml.telemetry.normalized` | Normalized/processed telemetry |
| `dnavio.frs.failures.reported` | Failure reports |
| `dnavio.dml.deadletter` | Unprocessable messages |

Access to specific topics is granted per client. Confirm with the D-NAVIO team which topics your client is authorized to use.


## 4. Notes and Constraints

- **No TLS in the current setup** — the connection uses `SASL_PLAINTEXT` (authenticated but not encrypted). If your compliance requirements mandate encryption in transit, raise this with the D-NAVIO team.
- **Token expiry** — tokens are short-lived. Both library examples above handle automatic refresh; no manual renewal is needed.
- **One client per application** — do not reuse the same `client_id` / `client_secret` across multiple applications or teams.
- **Topic access is scoped** — your client is granted access only to the topics agreed with D-NAVIO. Attempting to produce or consume from unauthorized topics will result in an authentication error.


## 5. Onboarding Checklist

Before going live, confirm the following with the D-NAVIO team:

- [ ] Client ID and Client Secret received
- [ ] Topics you need access to have been confirmed
- [ ] You have tested connectivity to `147.102.6.143:30094` from your network
- [ ] You have successfully obtained a token from the token endpoint
- [ ] A test message has been produced and consumed end-to-end

---

*For questions or access requests, contact the D-NAVIO platform team.*
