# Keycloak Guide

## Purpose

Keycloak is the identity and access management layer for the D-NAVIO platform.
It issues OAuth tokens that platform services and external partners use to
authenticate to platform resources — currently Kafka, and future backends.

## Realm and Client

| Object | Value | Notes |
|--------|-------|-------|
| Realm | `d-navio` | All platform auth lives here. `master` is admin-only. |
| Client | `dnavio-api` | Confidential, client-credentials (service account) flow. |

Both are created and reconciled automatically by the `keycloak-realm-bootstrap`
Helm hook Job on every install/upgrade — there are no manual UI steps. The
client's secret is taken from the `keycloak-client-secrets` Kubernetes Secret
(injected at deploy time, never committed).

## Stable Issuer (important)

Keycloak is pinned to a fixed frontend URL via `KC_HOSTNAME`
(`keycloak.hostname` in the Helm values, e.g. `https://147.102.6.143:30443`).

This guarantees every issued token carries the **same `iss` claim** regardless of
how it was requested — in-cluster (`keycloak:8080`), via the NodePort, or by a
partner. Kafka validates `iss` against this exact value, so it must be stable.
`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` lets in-cluster clients still reach the
token endpoint at `keycloak:8080` while receiving tokens stamped with the pinned
issuer. Kafka's `EXPECTED_ISSUER` is derived from the *same* `keycloak.hostname`
value, so issuer and expected-issuer can never drift.

## TLS

Keycloak serves both HTTP (`8080`, NodePort `30080`) and HTTPS (`8443`, NodePort
`30443`). The pinned hostname uses **HTTPS**, so all external/partner traffic —
where client secrets are POSTed — is encrypted.

The server certificate comes from the `dnavio-tls` Kubernetes Secret, generated
per-namespace by `scripts/tls/generate-dev-cert.sh` (a **self-signed dev CA**,
SAN = the node IP). Each environment (dev/integration/pilot) has its own CA. The
script writes the CA cert to `./<namespace>-ca.crt` — distribute that file
out-of-band to any client (curl, Kafka, a partner) that must validate the server;
it is git-ignored and never committed. In-cluster clients continue to use plain
HTTP on `keycloak:8080` (trusted network), so the broker's JWKS fetch never needs
to trust the self-signed cert.

> This is a dev CA. Replace it with a properly issued certificate in
> `feat/secrets-management` before production use.

## Persistence

Keycloak runs in `start-dev` mode with an H2 database stored on a
PersistentVolumeClaim (`keycloak-data`). The realm, client, and users therefore
survive pod restarts. (A production-grade external database is a later
hardening step.)

## Endpoints

| Context | URL |
|---------|-----|
| In-cluster (backchannel) | `http://keycloak:8080` |
| External / admin console | `https://147.102.6.143:30443` (HTTP `:30080` also open) |
| Token endpoint | `https://147.102.6.143:30443/realms/d-navio/protocol/openid-connect/token` |
| Issuer (`iss`) | `https://147.102.6.143:30443/realms/d-navio` |

## Admin Console

Open `https://147.102.6.143:30443` and log in with the admin credentials from the
`keycloak-credentials` Secret (username `admin`). The self-signed dev cert will
trigger a browser warning — expected. The "temporary admin user" banner is also
expected; creating a permanent admin account is a hardening follow-up.

## Getting a Token

Using the helper script (requires the client secret; point `KEYCLOAK_CACERT` at
the environment's CA file for the self-signed cert):

```bash
DNAVIO_CLIENT_SECRET=<secret> KEYCLOAK_CACERT=dnavio-dev-ca.crt \
  ./scripts/keycloak/get-token.sh
```

Or directly:

```bash
curl -s --cacert dnavio-dev-ca.crt -X POST \
  https://147.102.6.143:30443/realms/d-navio/protocol/openid-connect/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d grant_type=client_credentials \
  -d client_id=dnavio-api \
  -d client_secret=<secret>
```

Tokens are valid for 300 seconds. Kafka clients refresh them automatically.

## Health Check

```bash
./scripts/keycloak/check-keycloak.sh
```

Verifies the Keycloak pod is Running and the `d-navio` realm responds.

## Next Steps

- Replace the temporary admin with a permanent admin account
- Add a dedicated `kafka` audience mapper (tighter than the default `account`)
- Per-partner clients and realm roles (authorization) — `feat/rbac-access-model`
- Production CA-issued certificate + external database — `feat/secrets-management`
