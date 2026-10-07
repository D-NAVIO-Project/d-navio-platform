# Partner Onboarding Guide

This guide takes you from "we want to connect to D-NAVIO" to a running,
connected component. Read [How the platform works](#how-the-platform-works)
first (five minutes), then follow the steps for your path.

**Contents**
[How the platform works](#how-the-platform-works) ·
[Glossary](#glossary) ·
[Choose your path](#choose-your-path) ·
[Step 1 — Request access](#step-1--request-access-both-paths) ·
[Path A — In-cluster](#path-a--in-cluster) ·
[Path B — External](#path-b--external) ·
[Troubleshooting](#troubleshooting) ·
[Rules at a glance](#rules-at-a-glance)

---

## How the platform works

```
            ┌──────────────── D-NAVIO platform ────────────────┐
            │                                                  │
 your  ───► │  Keycloak ── issues a short-lived token          │
 component  │     │        to every component that proves      │
            │     │        its identity (client id + secret)   │
            │     ▼                                            │
            │  Kafka (message broker) ── topics:               │
 your  ◄──► │    dnavio.dml.telemetry.normalized               │ ◄──► other partners'
 component  │    dnavio.frs.failures.reported   ...            │      components
            │     ▲                                            │
            │     │ T4.2 (Data Management Layer) stores the    │
            │     │ data in its databases and serves history   │
            └──────────────────────────────────────────────────┘
```

Four ideas explain everything else in this guide:

1. **Components talk through Kafka topics, not to each other directly.** A
   component *produces* messages to a topic; any number of components
   *consume* them. You never need to know who is on the other side — only the
   topic and its message format (the *contract*).
2. **Every component proves who it is.** Before using Kafka, a component gets a
   token from Keycloak using its own *identity* (a client id and secret). Kafka
   rejects connections without a valid token, and can restrict which topics an
   identity may write to.
3. **Data lives with the Data Management Layer (T4.2).** T4.2 runs the
   platform's databases. Live data reaches you through Kafka topics; history
   older than a topic's retention comes from T4.2's services. You do not
   connect to the databases yourself.
4. **Everything you own carries your partner id.** If your id is `t42`, your
   services are `t42-ingest-api`, `t42-frs-api`, and so on. This keeps partners
   from colliding with each other on the shared platform.

---

## Glossary

| Term | Meaning |
|------|---------|
| **Partner id** | A short lowercase id for your organisation's components, e.g. `t42`. Prefix of everything you deploy. |
| **Component** | One of your services (one container image), e.g. `ingest-api`. |
| **Topic** | A named stream of messages in Kafka, e.g. `dnavio.frs.failures.reported`. |
| **Identity** | A Keycloak *service account* for your component: a **client id** and **client secret**. One identity can be shared by components with the same role. |
| **Token** | A short-lived (5 min) proof of identity your Kafka client fetches from Keycloak and renews automatically. |
| **OAUTHBEARER** | The Kafka authentication mechanism that uses those tokens. Standard in Kafka client libraries. |
| **Consumer group** | A name your consumer uses so Kafka remembers how far it has read. Use your own, e.g. `t42-frs-derive`. |
| **Secret** | Where the platform stores credentials inside the cluster. Your components receive them as environment variables; you never see the values. |
| **Values file** | `deploy/dnavio-values.yaml` in your repository: a short description of your components (image, port, memory, settings). |
| **Component chart** | The platform's template that turns your values file into running services. You don't edit it. |
| **Own chart** | Your own Helm chart, only for things the component chart cannot run (e.g. a database). Optional. |
| **Health endpoint** | An HTTP path (e.g. `/healthz`) that returns 200 when your service is working. The platform uses it to know when your service is ready and to restart it if it hangs. |

---

## Choose your path

| | **In-cluster** | **External** |
|---|---|---|
| Where your components run | On the D-NAVIO platform cluster | In your own environment (e.g. MAG) |
| How you reach Kafka | `kafka:9092` inside the cluster | The external broker address over TLS (sent with your credentials) |
| Credentials | Injected into your components — you never handle them | Sent to you through a private channel |
| How you deploy | Push to your repository; shared workflows deploy | Yourself, in your environment |
| What you do | [Step 1](#step-1--request-access-both-paths), then [Path A](#path-a--in-cluster) | [Step 1](#step-1--request-access-both-paths), then [Path B](#path-b--external) |

---

## Step 1 — Request access (both paths)

Open a **Partner onboarding request** issue in this repository:
**Issues → New issue → Partner onboarding request**.

> **This repository is public, so the issue is visible to anyone.** Never put
> passwords, tokens, internal hostnames, IP addresses or personal data in it.

### Filling in the form

| Field | How to decide |
|-------|---------------|
| **Partner id** | Short and stable — it becomes part of every resource name. Your task or tool name works well (`t42`, `dss`, `xai`). |
| **Hosting** | *In-cluster* if your components should run on the platform; *External* if they run in your own environment. |
| **Components** (in-cluster) | One line per service, with a memory estimate (see [choosing memory](#choosing-memory)). |
| **Identities** | One per **role**. Components that produce and consume the same topics can share one identity; give a component its own identity if it needs different topic access. Name them `svc-<role>`, e.g. `svc-dml`. |
| **Topics you produce** | Name them `dnavio.<component>.<entity>.<qualifier>` (e.g. `dnavio.dss.recommendations.issued`). Give the expected rate (messages per second or per day) and how long they must be kept. |
| **Topics you consume** | Existing topics you read — see the [topic catalogue](#a3-using-platform-data). |
| **Datastores** | Only if you will run your own (rare — most partners use platform data through Kafka). |
| **Message contract** | Link to an [AsyncAPI](https://www.asyncapi.com/) description of the topics you produce, if you have one. |

### What happens next

The NTUA team reviews the request, then creates your identities, topics and access rules, and replies on the issue with
what you need for the next steps, for example:

> Approved. Identity `svc-dss`: use `credentials/svc-dss-client-id` and
> `credentials/svc-dss-client-secret` in your values file. Topics: you may
> produce to `dnavio.dss.recommendations.issued` and consume
> `dnavio.dml.telemetry.normalized`. Memory budget: 512Mi. Reference the
> shared workflows as `@main`.

For an **external** partner, the reply only confirms approval; your
credentials are sent through a private channel.

**To change anything later** (a new topic, another identity, more memory),
comment on the same issue.

---

## Path A — In-cluster

You will: prepare your code (A2), decide how you get data (A3), describe your
components in a values file (A4), optionally add your own chart (A5), and add a
workflow that deploys on every push (A6). Then verify (A7).

### A1. What the platform gives you

| | |
|---|---|
| Kafka | `kafka:9092` — security protocol `SASL_PLAINTEXT`, mechanism `OAUTHBEARER` |
| Token endpoint | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` |
| Your identities | In your values file as `credentials/<client>-client-id` and `credentials/<client>-client-secret` |
| Your own secrets | Secret `<partner>-secrets`, in your values file as `partner/<key>` (e.g. third-party API keys) |
| Object storage | MinIO, on request |

Inside the cluster no TLS certificate is needed: traffic stays on the
platform's internal network.

### A2. Prepare your code

**1. Read all settings from environment variables.** Broker address, token
endpoint, client id, client secret — nothing hard-coded. You choose the
variable names; the values file maps platform values onto them (A4).

**2. Authenticate to Kafka with OAUTHBEARER.** Your client fetches a token from
Keycloak with its client id and secret, and renews it before it expires.

Python (`pip install confluent-kafka requests`):

```python
import os, time, requests
from confluent_kafka import Producer

def fetch_token(_config):
    resp = requests.post(
        os.environ["KAFKA_TOKEN_URL"],
        data={"grant_type": "client_credentials",
              "client_id": os.environ["KAFKA_CLIENT_ID"],
              "client_secret": os.environ["KAFKA_CLIENT_SECRET"]},
        timeout=10,
    )
    resp.raise_for_status()
    token = resp.json()
    return token["access_token"], time.time() + token["expires_in"]

conf = {
    "bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],   # kafka:9092
    "security.protocol": "SASL_PLAINTEXT",
    "sasl.mechanism": "OAUTHBEARER",
    "oauth_cb": fetch_token,
}

def produce(topic, payload: bytes):
    result = {}
    p = Producer(conf)
    p.produce(topic, value=payload,
              on_delivery=lambda err, _msg: result.update(error=err))
    if p.flush(10) or result.get("error"):
        # A rejected message (e.g. no permission on the topic) is only
        # reported here — flush() alone does not show it.
        raise RuntimeError(f"delivery failed: {result.get('error')}")
```

Go ([franz-go](https://github.com/twmb/franz-go)):

```go
import (
	"context"
	"os"

	"github.com/twmb/franz-go/pkg/kgo"
	"github.com/twmb/franz-go/pkg/sasl/oauth"
	"golang.org/x/oauth2/clientcredentials"
)

func newClient(ctx context.Context) (*kgo.Client, error) {
	// Caches the token and fetches a new one before it expires.
	tokens := (&clientcredentials.Config{
		ClientID:     os.Getenv("KAFKA_CLIENT_ID"),
		ClientSecret: os.Getenv("KAFKA_CLIENT_SECRET"),
		TokenURL:     os.Getenv("KAFKA_TOKEN_URL"),
	}).TokenSource(ctx)

	return kgo.NewClient(
		kgo.SeedBrokers(os.Getenv("KAFKA_BOOTSTRAP")), // kafka:9092
		kgo.SASL(oauth.Oauth(func(context.Context) (oauth.Auth, error) {
			t, err := tokens.Token()
			if err != nil {
				return oauth.Auth{}, err
			}
			return oauth.Auth{Token: t.AccessToken}, nil
		})),
	)
}
```

Java and other languages: see the
[Kafka integration guide](kafka-partner-integration.md#6-code-examples), using
the in-cluster values above (no TLS, no CA certificate).

**3. Add a health endpoint** — an HTTP path returning 200 when the service
works, e.g. in FastAPI:

```python
@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```

If you can, also add a *readiness* path (e.g. `/readyz`) that returns 200 only
once the service has connected to what it needs; the platform then sends no
traffic until it is ready.

**4. Package each service as a container image** with a Dockerfile. One image
per service; a single Dockerfile with a build argument for the service name
also works (see A6).

**5. Don't bundle platform services.** No Kafka, Redpanda or Keycloak of your
own — use the platform's.

### A3. Using platform data

Subscribe to topics to receive data as it is produced:

| Topic | Produced by | Contains | Kept for |
|-------|-------------|----------|----------|
| `dnavio.dml.telemetry.normalized` | T4.2 (DML) | Validated, normalised telemetry — **the topic most consumers want** | 7 days |
| `dnavio.dml.telemetry.raw` | Data sources (via T4.2 ingestion) | Telemetry as received | 7 days |
| `dnavio.dml.deadletter` | T4.2 (DML) | Messages that failed validation | 30 days |
| `dnavio.frs.failures.reported` | T4.2 (FRS) | Failure records | Indefinitely |
| `dnavio.frs.hydra.probability-update` | T4.2 (FRS) | HYDRA root-node probability updates | 30 days |
| `dnavio.hydra.riskscores` | HYDRA | Risk scores | 7 days (broker default) |
| `dnavio.frs.incidents.cyber` | Cybersecurity toolkit | Cyber incidents | Indefinitely |

Message formats are defined in T4.2's contracts
(`contracts/` in `d-navio-t4.2`); ask the NTUA team for access.

**History.** Topics keep data for a limited time (above), so Kafka is not an
archive. Data older than that is held by T4.2, which plans to serve historical
queries (time windows, exports) through its query service. Ask on your
onboarding issue if you need history.

**Consumer groups.** Give each consumer its own group id, prefixed with your
partner id (`t42-frs-derive`). Two components sharing a group id split the
messages between them instead of each receiving all of them.

### A4. Describe your components in a values file

Add `deploy/dnavio-values.yaml` to your repository:

```yaml
partner: dss                          # your partner id
components:
  - name: recommender                 # becomes dss-recommender
    image: dss/recommender            # <partner>/<name>; no tag — the build adds it
    port: 8080                        # the port your service listens on
    health: { readiness: /readyz, liveness: /healthz }
    memory: 256Mi                     # see "Choosing memory"
    env:                              # plain settings, visible in your repository
      KAFKA_BOOTSTRAP: kafka:9092
      KAFKA_TOKEN_URL: http://keycloak:8080/realms/d-navio/protocol/openid-connect/token
      LOG_LEVEL: info
    secretEnv:                        # credentials, injected from the platform
      KAFKA_CLIENT_ID: credentials/svc-dss-client-id
      KAFKA_CLIENT_SECRET: credentials/svc-dss-client-secret
```

| Field | What to put |
|-------|-------------|
| `partner` | Your partner id. |
| `name` | The service name, lowercase with hyphens. Your service becomes `<partner>-<name>`; other components reach it at `http://<partner>-<name>:<port>`. |
| `image` | `<partner>/<name>` — must match the `image` your build workflow uses (A6). Never a tag. |
| `port` | The port your service listens on. Omit for background workers (then give `healthCommand`, a command that exits 0 when healthy). |
| `health` | One path for both checks, or `{readiness: ..., liveness: ...}`. |
| `memory` | Request **and** limit. If your service uses more, it is restarted (`OOMKilled`). |
| `env` | Non-secret settings. **Variable names are your application's own** — whatever A2 reads. |
| `secretEnv` | Credentials: `VARIABLE: <alias>/<key>`, with the aliases `credentials/...` (your identities) and `partner/...` (your own Secret). Anything named like `*PASSWORD*`, `*SECRET*`, `*TOKEN*` must go here — the deploy refuses it in `env`. |
| `cpu`, `replicas`, `command`, `args` | Optional. |

<a id="choosing-memory"></a>**Choosing memory.** Start from what the service
uses on your machine plus ~50%. Typical starting points: Go 64Mi,
Python/Node.js 128–256Mi, Java (JVM) 512Mi or more. The sum of your
components must stay within the budget agreed on your onboarding issue.

The deploy is **refused with a message naming the component and field** if
the values file bundles a platform service or a database, misses memory or a
health check, pins an image tag, or puts a credential in `env`. Full reference:
[helm/dnavio-component/README.md](../helm/dnavio-component/README.md); a
complete six-service example:
[examples/t42-values.yaml](../helm/dnavio-component/examples/t42-values.yaml).

### A5. Your own chart (optional)

Only needed for something the component chart cannot run — typically a
database (T4.2's datastores). Most partners skip this step.

Start from the reference chart
[examples/infra-chart](../helm/dnavio-component/examples/infra-chart): a
PostgreSQL with a password generated on first install and a ready-made
connection string in `<partner>-secrets` (your services read it as
`partner/postgres-dsn`). Copy it to e.g. `deploy/infra` in your repository.
Files placed in its `initdb/` folder run once, when the database is first
created.

Your chart is deployed as release `<partner>-infra`, **before** your
components, and is checked first. The deploy is refused if it:

- creates anything not named `<partner>-...`, or in another namespace;
- creates kinds other than Deployment, StatefulSet, Job, CronJob, Service,
  ConfigMap, Secret, PersistentVolumeClaim (permissions and cluster-wide
  resources stay with the NTUA team);
- exposes a Service outside the cluster (only `ClusterIP`);
- misses a memory limit on any container;
- uses host networking, host paths or privileged containers;
- runs a platform service image (Kafka, Keycloak, MinIO);
- puts a credential in a plain environment variable.

### A6. Add the deploy workflow

Add `.github/workflows/dnavio-deploy.yml` to your repository. It runs on every
push to `main` (and on demand from the Actions tab):

```yaml
name: Deploy to D-NAVIO
on:
  push:
    branches: [main]
  workflow_dispatch:            # adds a "Run workflow" button

permissions:
  contents: read

jobs:
  build:                        # one image per service, built on the platform
    strategy:
      max-parallel: 1           # one shared build machine
      matrix:
        service: [recommender, scorer]
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/build-component.yml@main
    with:
      partner: dss
      image: ${{ matrix.service }}       # built as dss/<service>
      dockerfile: Dockerfile             # path in your repository
      build-args: SERVICE=${{ matrix.service }}   # only if one Dockerfile builds several services

  deploy:
    needs: build
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/deploy-component.yml@main
    with:
      partner: dss
      values: deploy/dnavio-values.yaml
      # chart: deploy/infra             # only with your own chart (A5)
      environment: dev
      logs: true                         # print startup logs after deploying
```

> While the shared workflows are in preview, the NTUA team will tell you which
> version to reference instead of `@main`.

### A7. Deploy, verify and debug

Push to `main`, then open **Actions → Deploy to D-NAVIO** in your repository.

- **Green run**: the run summary lists your pods as `Running`. With
  `logs: true`, expand *Pod logs* to see each service's startup — check that it
  connected to Kafka without errors.
- **Red run**: the step that failed tells you why. Rule violations name the
  field to fix; if a pod did not start, *Diagnostics* shows its events and
  recent logs. See [Troubleshooting](#troubleshooting).
- **End-to-end check**: produce one test message to a topic you own and confirm
  that your consumer (or the consuming partner) receives it.

You do not need cluster access: everything is visible in the workflow run.
**If your repository is public, so are these logs.**

### A8. Checklist

- [ ] Onboarding request approved; identities, topics and budget in the NTUA reply
- [ ] Settings read from environment variables
- [ ] Kafka client uses OAUTHBEARER and checks delivery errors
- [ ] Health endpoint in every service
- [ ] `deploy/dnavio-values.yaml` added; image names match the build workflow
- [ ] Deploy workflow added; first run green
- [ ] Test message produced and received

---

## Path B — External

Your components run in your own environment and connect over the network.

1. **Receive your credentials.** Once your request is approved, the NTUA team
   sends you, through a private channel (never the issue): your client id and
   client secret, the D-NAVIO CA certificate (`ca.crt`), and the platform
   endpoints — the broker address (`<broker>`) and the Keycloak base URL
   (`<keycloak>`).
2. **Check your network can reach the platform** (both endpoints) — see the
   [Kafka integration guide, section 2](kafka-partner-integration.md#2-network-requirements).
3. **Connect to Kafka** following the
   [Kafka integration guide](kafka-partner-integration.md): broker `<broker>`
   over TLS (`SASL_SSL`, trusting `ca.crt`), token endpoint
   `<keycloak>/realms/d-navio/protocol/openid-connect/token`.
4. **Browser login for your users** (if you have a user interface): see the
   [SSO integration guide](sso-partner-integration.md).

The [topic catalogue](#a3-using-platform-data) and the rules on consumer groups
apply to you as well.

---

## Troubleshooting

| You see | Likely cause | Fix |
|---------|--------------|-----|
| Deploy refused: `components.<name>: ...` | The values file breaks a rule | Do what the message says (add `memory`, move a variable to `secretEnv`, ...) |
| Deploy refused: `<Kind>/<name>: ...` (own chart) | Your own chart breaks a rule | Fix the resource named in the message — see A5 |
| `image <partner>/<x> has not been built` | The build job did not build it for this commit, or the names differ | Make the build's `image:` and the values file's `image:` match |
| Pod `CreateContainerConfigError` | A `secretEnv` key does not exist | Check the key against the NTUA reply; for `partner/...`, check your own chart creates it |
| Pod not ready, restarting | Health path or port wrong, or the service crashes on start | Check the logs in *Diagnostics*; check `port` and `health` |
| `OOMKilled` | The service needs more memory | Raise `memory` (within your budget) |
| Kafka: `SASL authentication failed` / invalid token | Wrong client id/secret mapping or token URL | Check `secretEnv` and the token endpoint variable |
| Kafka: `TOPIC_AUTHORIZATION_FAILED` | Your identity may not write to that topic | Request it on your onboarding issue |
| Kafka: `UNKNOWN_TOPIC_OR_PARTITION` | The topic does not exist | Request it on your onboarding issue |
| Consumer receives nothing | Group already read to the end, or nothing produced yet | Check the group id; produce a test message |
| Workflow: `workflow was not found` | Wrong `@ref` for the shared workflows | Use the ref the NTUA team gave you |

Still stuck? Comment on your onboarding issue with a link to the failed run.

---

## Rules at a glance

| Do | Don't |
|---|---|
| Use the platform's Kafka and Keycloak | Run your own Kafka, Redpanda or Keycloak |
| Get data through topics; ask T4.2 for history | Connect to the platform databases directly |
| Prefix everything with your partner id | Use generic names (`api`, `postgres`) |
| Keep credentials in `secretEnv` | Put credentials in values files, issues or code |
| Set memory and health checks | Deploy without limits — the platform is shared |
| Name topics `dnavio.<component>.<entity>.<qualifier>` | Write to topics you have not requested |
| Request changes on your onboarding issue | Change platform resources yourself |

---

*Questions: comment on your onboarding issue, or contact the NTUA team.*
