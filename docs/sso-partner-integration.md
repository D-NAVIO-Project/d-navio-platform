# D-NAVIO SSO Integration Guide for Partners

D-NAVIO uses [Keycloak](https://www.keycloak.org/) as its identity provider. Partners can integrate in two ways:

- **Scenario A** — Partner application uses D-NAVIO Keycloak to authenticate its users (browser login)
- **Scenario B** — Partner has their own identity provider (Active Directory, Azure AD, Okta, etc.) and wants users to log in with their existing company credentials

Both scenarios result in the same outcome: users get a JWT token issued by D-NAVIO Keycloak, usable across all D-NAVIO services.

---

## D-NAVIO Identity Provider Details

| Parameter | Value |
|-----------|-------|
| **Keycloak base URL** | `http://147.102.6.143:30080` |
| **Realm** | `d-navio` |
| **OIDC discovery endpoint** | `http://147.102.6.143:30080/realms/d-navio/.well-known/openid-configuration` |
| **Authorization endpoint** | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/auth` |
| **Token endpoint** | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/token` |
| **JWKS endpoint** | `http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect/certs` |

> The discovery endpoint returns all URLs above automatically. Most OIDC libraries only need the base URL + realm name.

---

## Scenario A — Browser-based SSO (no existing IdP)

Use this when: partner users will create accounts in D-NAVIO Keycloak, or accounts are provisioned by the D-NAVIO team.

### Step 1 — D-NAVIO sets up a client in Keycloak

The D-NAVIO team performs this in the Keycloak admin console (`http://147.102.6.143:30080` → Admin → `d-navio` realm):

1. **Clients → Create client**
   - Client type: `OpenID Connect`
   - Client ID: `partner-<name>` (e.g. `partner-maggioli`)
   - Click **Next**

2. **Authentication settings**
   - Standard flow: **On** (Authorization Code)
   - Direct access grants: **Off**
   - Click **Next**

3. **Login settings**
   - Valid redirect URIs: `https://your-partner-app.com/*`
   - Web origins: `https://your-partner-app.com`
   - Click **Save**

4. **Credentials tab**
   - If the application is a server-side app (confidential client): copy the **Client Secret**
   - If it is a browser-only SPA: set **Client authentication** to Off (PKCE, no secret needed)

5. **What to give the partner**
   - `client_id` (e.g. `partner-maggioli`)
   - `client_secret` (only for server-side apps)
   - Redirect URI they must register in their app

---

### Step 2 — Partner integrates OIDC in their application

**What the partner needs to implement:**

1. Redirect unauthenticated users to the Keycloak authorization URL
2. Handle the callback (Keycloak redirects back with an authorization code)
3. Exchange the code for tokens (access token + refresh token)
4. Use the access token on subsequent requests to D-NAVIO APIs or Kafka

---

#### Python (Authlib + FastAPI)

```bash
pip install authlib httpx fastapi uvicorn
```

```python
from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from authlib.integrations.httpx_client import AsyncOAuth2Client
import os

app = FastAPI()

CLIENT_ID     = "partner-maggioli"
CLIENT_SECRET = "your-client-secret"   # omit for public/PKCE clients
REDIRECT_URI  = "https://your-app.com/callback"
KEYCLOAK_BASE = "http://147.102.6.143:30080/realms/d-navio/protocol/openid-connect"

@app.get("/login")
async def login():
    client = AsyncOAuth2Client(client_id=CLIENT_ID, redirect_uri=REDIRECT_URI)
    url, state = client.create_authorization_url(f"{KEYCLOAK_BASE}/auth")
    return RedirectResponse(url)

@app.get("/callback")
async def callback(request: Request):
    client = AsyncOAuth2Client(
        client_id=CLIENT_ID,
        client_secret=CLIENT_SECRET,
        redirect_uri=REDIRECT_URI,
    )
    token = await client.fetch_token(
        f"{KEYCLOAK_BASE}/token",
        authorization_response=str(request.url),
    )
    # token["access_token"] is now usable for D-NAVIO APIs / Kafka
    return {"access_token": token["access_token"]}
```

---

#### JavaScript / TypeScript (next-auth, suitable for Next.js)

```bash
npm install next-auth
```

```ts
// pages/api/auth/[...nextauth].ts
import NextAuth from "next-auth";

export default NextAuth({
  providers: [
    {
      id: "keycloak",
      name: "D-NAVIO",
      type: "oauth",
      wellKnown: "http://147.102.6.143:30080/realms/d-navio/.well-known/openid-configuration",
      clientId: "partner-maggioli",
      clientSecret: "your-client-secret",
      authorization: { params: { scope: "openid profile email" } },
      profile(profile) {
        return { id: profile.sub, name: profile.name, email: profile.email };
      },
    },
  ],
});
```

Users visiting your app are redirected to D-NAVIO Keycloak login automatically.

---

#### Java (Spring Boot + Spring Security OAuth2)

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-client</artifactId>
</dependency>
```

```yaml
# application.yml
spring:
  security:
    oauth2:
      client:
        registration:
          dnavio:
            client-id: partner-maggioli
            client-secret: your-client-secret
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/login/oauth2/code/dnavio"
            scope: openid, profile, email
        provider:
          dnavio:
            issuer-uri: http://147.102.6.143:30080/realms/d-navio
```

Spring Security handles the full login/callback flow automatically.

---

## Scenario B — Identity Federation (partner has existing IdP)

Use this when: the partner already manages users in Active Directory, Azure AD, Okta, or another SAML/OIDC provider and does not want to maintain separate accounts in D-NAVIO Keycloak.

### Overview

```
Partner user → Partner IdP (e.g. Azure AD) → D-NAVIO Keycloak → D-NAVIO services
```

Keycloak acts as a broker: it trusts the partner's IdP and translates their tokens into D-NAVIO tokens.

---

### Step 1 — Partner provides their IdP metadata

The partner must share one of:

- **For OIDC IdPs** (Azure AD, Okta, Google Workspace): their OIDC discovery URL (e.g. `https://login.microsoftonline.com/<tenant-id>/v2.0/.well-known/openid-configuration`)
- **For SAML IdPs** (AD FS, Shibboleth): their SAML metadata XML or metadata URL

---

### Step 2 — D-NAVIO configures the Identity Provider in Keycloak

In Keycloak admin → `d-navio` realm → **Identity Providers → Add provider**:

**For Azure AD / Okta (OIDC):**

| Field | Value |
|-------|-------|
| Provider type | OpenID Connect v1.0 |
| Alias | `partner-<name>` |
| Discovery URL | *(partner's OIDC discovery URL)* |
| Client ID | *(registered in partner's Azure AD / Okta)* |
| Client Secret | *(from partner's Azure AD / Okta app registration)* |
| Sync mode | `Force` (always pull latest claims) |

**For Active Directory / SAML:**

| Field | Value |
|-------|-------|
| Provider type | SAML v2.0 |
| Alias | `partner-<name>` |
| Service Provider Entity ID | `http://147.102.6.143:30080/realms/d-navio` |
| IdP Metadata | *(paste partner's XML or URL)* |

After saving, Keycloak generates a **Service Provider metadata URL** that the partner must register in their IdP.

---

### Step 3 — Claim mapping (optional but recommended)

Keycloak can map claims from the partner's token to D-NAVIO roles:

**Identity Providers → *(your provider)* → Mappers → Add mapper**

| Mapper type | Use case |
|-------------|----------|
| Attribute importer | Pull `email`, `name`, etc. from partner token |
| Role importer | Map partner groups/roles to D-NAVIO roles |
| Hardcoded role | Assign a fixed D-NAVIO role to all federated users |

---

### Step 4 — What the partner registers in their IdP

Once Keycloak is configured, provide the partner with:

| Item | Value |
|------|-------|
| **SP Entity ID / Issuer** | `http://147.102.6.143:30080/realms/d-navio` |
| **Redirect / Callback URI** | `http://147.102.6.143:30080/realms/d-navio/broker/partner-<name>/endpoint` |
| **SAML metadata URL** (SAML only) | `http://147.102.6.143:30080/realms/d-navio/protocol/saml/descriptor` |

The partner registers these in their Azure AD app registration, Okta application, or AD FS relying party.

---

## What the partner application receives (both scenarios)

After a successful login, the partner application receives:

```json
{
  "access_token": "<JWT>",
  "refresh_token": "<JWT>",
  "token_type": "Bearer",
  "expires_in": 300
}
```

The `access_token` is a signed JWT issued by D-NAVIO Keycloak. It can be:
- Passed as `Authorization: Bearer <token>` to D-NAVIO REST APIs
- Used as the OAUTHBEARER credential for Kafka (see [kafka-partner-integration.md](kafka-partner-integration.md))
- Verified locally by decoding and checking the signature against the JWKS endpoint

---

## Onboarding Checklist

### Scenario A (D-NAVIO manages users)
- [ ] Partner provides redirect URIs for their application
- [ ] D-NAVIO creates client in Keycloak and shares `client_id` (and `client_secret` if needed)
- [ ] Partner user accounts created or self-registration enabled in Keycloak
- [ ] Partner tests login flow end-to-end

### Scenario B (Identity federation)
- [ ] Partner shares their IdP metadata or OIDC discovery URL
- [ ] D-NAVIO configures Identity Provider in Keycloak
- [ ] D-NAVIO shares SP metadata / callback URI with partner
- [ ] Partner registers D-NAVIO as a trusted SP in their IdP
- [ ] Claim mapping reviewed and configured
- [ ] Partner tests federated login end-to-end

---

*For access requests or integration support, contact the D-NAVIO platform team.*
