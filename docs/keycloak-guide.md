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
(`keycloak.hostname` in the Helm values, e.g. `http://147.102.6.143:30080`).

This guarantees every issued token carries the **same `iss` claim** regardless of
how it was requested — in-cluster (`keycloak:8080`), via the NodePort, or by a
partner. Kafka validates `iss` against this exact value, so it must be stable.
`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` lets in-cluster clients still reach the
token endpoint at `keycloak:8080` while receiving tokens stamped with the pinned
issuer.

## Persistence

Keycloak runs in `start-dev` mode with an H2 database stored on a
PersistentVolumeClaim (`keycloak-data`). The realm, client, and users therefore
survive pod restarts. (A production-grade external database is a later
hardening step.)

## Endpoints

| Context | URL |
|---------|-----|
| In-cluster | `http://keycloak:8080` |
| External / admin console | `http://147.102.6.143:30080` |
| Token endpoint | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token` |
| Issuer (`iss`) | `http://147.102.6.143:30080/realms/d-navio` |

## Admin Console

Open `http://147.102.6.143:30080` and log in with the admin credentials from the
`keycloak-credentials` Secret (username `admin`). The "temporary admin user"
banner is expected; creating a permanent admin account is a hardening follow-up.

## Getting a Token

Using the helper script (requires the client secret):

```bash
DNAVIO_CLIENT_SECRET=<secret> ./scripts/keycloak/get-token.sh
```

Or directly:

```bash
curl -s -X POST \
  http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token \
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
- TLS and an external database — `feat/secrets-management`
