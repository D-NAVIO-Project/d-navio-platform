# Partner Onboarding Guide

This guide takes you from your **D-NAVIO Component & Interfaces
Specification** to a running, connected component. It tells you, step by
step, what to do, how to do it, and how to check that it worked.

Read [How the platform works](#how-the-platform-works) and
[From your specification to the platform](#from-your-specification-to-the-platform)
first (five minutes), then follow the steps for your hosting location.

**Contents**
[How the platform works](#how-the-platform-works) ·
[From your specification to the platform](#from-your-specification-to-the-platform) ·
[Glossary](#glossary) ·
[Choose your path](#choose-your-path) ·
[Step 1 — Request access](#step-1--request-access-both-paths) ·
[Path A — Hosted at NTUA](#path-a--hosted-at-ntua) ·
[Path B — Hosted at your premises](#path-b--hosted-at-your-premises) ·
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
            │  Message Broker (Kafka) ── channels (topics):    │
 your  ◄──► │    dnavio.dml.telemetry.normalized               │ ◄──► other D-NAVIO
 component  │    dnavio.frs.failures.reported   ...            │      components
            │     ▲                                            │
            │     │ T4.2 (Data Management Layer) stores the    │
            │     │ data in its databases and serves history   │
            └──────────────────────────────────────────────────┘
```

Four ideas explain everything else in this guide:

1. **Components exchange data through the Message Broker, not directly.** A
   component *produces* messages to a channel — a Kafka *topic*; any number of
   components *consume* them. You never need to know who is on the other side
   — only the topic and its message format (the *contract*).
2. **Every component proves who it is.** Before using the Message Broker, a
   component gets a token from Keycloak using its own *identity* (a client id
   and secret). Kafka rejects connections without a valid token, and can
   restrict which topics an identity may write to.
3. **Pilot data lives with the Data Management Layer (T4.2).** T4.2 runs the
   platform's databases. Live pilot data reaches you through topics;
   historical pilot data — older than a topic keeps — comes from T4.2's
   services. You do not connect to the databases yourself.
4. **Everything you deploy carries your Component ID.** If your Component ID
   is `XYZ`, your containers are `xyz-inference-api`, `xyz-detector`, and so
   on, and your topics are `dnavio.xyz.…`. This keeps components from
   colliding with each other on the shared platform.

---

## From your specification to the platform

Your Component & Interfaces Specification already describes most of what the
platform needs. This table shows where each part of it ends up:

| In your specification | On the platform | Where in this guide |
|---|---|---|
| **Component ID** (e.g. `XYZ`) | In lowercase, the prefix of everything you deploy: `xyz` | [Step 1](#step-1--request-access-both-paths), [A4](#a4-describe-your-containers-in-a-values-file) |
| **Hosted Location**: NTUA premises / Local premises / Both | Path A / Path B / both | [Choose your path](#choose-your-path) |
| **Internal container / pod** — Container / Pod ID (e.g. `xyz-inference-api`) | One entry in your values file; the container runs under that name | [A4](#a4-describe-your-containers-in-a-values-file) |
| **Image / repository** | Your Git repository. Images are built from it on the platform — no registry or version tags needed | [A2](#4-write-a-dockerfile), [A6](#a6-add-the-deploy-pipeline) |
| **Connection to Message Broker and channel used** | A Kafka topic named `dnavio.<cmp>.<entity>.<qualifier>`, created by the NTUA team | [Step 1](#step-1--request-access-both-paths), [A3](#a3-using-platform-data) |
| **Inputs** — Live pilot data, D-NAVIO component output | Topics you consume | [A3](#a3-using-platform-data) |
| **Inputs** — Historical pilot data | T4.2's history service | [A3](#a3-using-platform-data) |
| **Outputs** (through the Message Broker) | Topics you produce | [A3](#a3-using-platform-data) |
| **Format & example** | The message contract for a topic | [A3](#a3-using-platform-data) |
| **Triggers** | How your code starts work: a topic consumer, an HTTP endpoint, a timer | [A2](#matching-your-triggers) |
| **Exposed ports / endpoints** | `port` and health check of a container | [A4](#a4-describe-your-containers-in-a-values-file) |
| **Resources** — RAM, Cores | `memory`, `cpu` of a container | [A4](#choosing-memory) |
| **Resources** — GPU | Not part of the standard setup; the NTUA team confirms what is possible | — |
| **Persistent storage** | Your own chart (e.g. a database with a volume) | [A5](#a5-your-own-chart-optional) |
| **Does it have its own UI?** | Access from outside the platform is arranged with the NTUA team | [A1](#a1-what-the-platform-gives-you) |

> **Two kinds of "workflow".** In the specification, a *workflow*
> (`<CMP>.wf.0X`) is an end-to-end interaction between components. This guide
> also uses a GitHub Actions workflow file that builds and deploys your
> containers; to keep the two apart, this guide calls that file the **deploy
> pipeline**.

---

## Glossary

| Term | Meaning |
|------|---------|
| **Component** | One D-NAVIO tool, as in your specification. One specification per component. This guide uses a made-up component with Component ID `XYZ` in its examples. |
| **Component ID** | The component's abbreviation from the specification. Written in lowercase (`xyz`), it is the prefix of every container, topic and consumer group you create. |
| **Container** | One part of a component that runs as its own process, from one container image — an *internal container / pod* in the specification, e.g. `xyz-inference-api`. |
| **Channel / topic** | A named stream of messages in the Message Broker (Kafka), e.g. `dnavio.frs.failures.reported`. The specification says *channel*; Kafka says *topic*. |
| **Identity** | A Keycloak *service account*: a **client id** and **client secret**. Containers with the same role can share one identity. |
| **Token** | A short-lived (5 min) proof of identity your Kafka client fetches from Keycloak and renews automatically. |
| **OAUTHBEARER** | The Kafka authentication mechanism that uses those tokens. Standard in Kafka client libraries. |
| **Consumer group** | A name your consumer uses so Kafka remembers how far it has read. Use your own, e.g. `xyz-detector`. |
| **Secret** | Where the platform stores credentials. Your containers receive them as environment variables; you never see the values. |
| **Values file** | `deploy/dnavio-values.yaml` in your repository: a short description of your containers (image, port, memory, settings). |
| **Component chart** | The platform's template that turns your values file into running containers. You don't edit it. |
| **Own chart** | Your own Helm chart, only for things the component chart cannot run (e.g. a database with persistent storage). Optional. |
| **Deploy pipeline** | `.github/workflows/dnavio-deploy.yml` in your repository: the GitHub Actions workflow that builds and deploys your containers on every push. |
| **Health check** | An HTTP path (e.g. `/healthz`) or command that succeeds when your container is working. The platform uses it to know when your container is ready and to restart it if it hangs. |

---

## Choose your path

Use the **Hosted Location** from your specification:

| | **NTUA premises** → [Path A](#path-a--hosted-at-ntua) | **Local premises** → [Path B](#path-b--hosted-at-your-premises) |
|---|---|---|
| Where your containers run | On the D-NAVIO platform at NTUA | In your own environment (e.g. MAG) |
| How you reach the Message Broker | `kafka:9092` inside the platform | The external broker address over TLS (sent with your credentials) |
| Credentials | Injected into your containers — you never handle them | Sent to you through a private channel |
| How you deploy | Push to your repository; the deploy pipeline does the rest | Yourself, in your environment |

**Both:** follow Path A for the containers marked *Hosted in NTUA premises: Y*
in your specification, and Path B for the others. They talk to each other
through topics, as any two components do.

Every component starts with [Step 1](#step-1--request-access-both-paths).

---

## Step 1 — Request access (both paths)

Before you write any deployment files, ask the NTUA team to set you up. They
read your specification, create your identities, topics and access rules, and
tell you the names to use in the later steps.

**What to do:**

1. Complete your Component & Interfaces Specification (one per component).
2. Email it to **`<NTUA contact email>`**, subject
   `D-NAVIO onboarding request — <Component ID>`, with the short form below
   for the platform details the specification does not cover.
3. Wait for the reply (see [What happens next](#what-happens-next)) before
   starting Path A or B — you need the names it contains.

```text
Component ID:       (from the specification, e.g. XYZ)
Specification:      (attached, or its SharePoint path)
Technical contact:  (name, email)
Repository:         (containers hosted at NTUA: your repository in the D-NAVIO-Project GitHub organisation)

Identities — one per role: name — which containers use it
  - svc-...

Topics you produce — topic name — Output ID(s) — how long messages must be kept
  -

Third-party credentials needed (names only, never values):
Object storage (MinIO) needed: yes | no
Notes:
```

> Never put passwords, tokens or secrets in the request or the
> specification. Credentials are exchanged separately (see
> [Path B](#path-b--hosted-at-your-premises)).

### Filling in the form

| Field | How to decide |
|-------|---------------|
| **Component ID** | As in your specification. In lowercase it prefixes everything you deploy, so keep it short and stable. |
| **Repository** | Containers hosted at NTUA are built and deployed from a repository in the `D-NAVIO-Project` GitHub organisation — the platform's build machine only runs jobs for repositories there. If you don't have one yet, ask in the email and the NTUA team will create it. Put the same repository in the specification's *Image / repository* field. |
| **Identities** | One per **role**. Containers that produce and consume the same topics can share one identity; give a container its own identity if it needs different topic access. Name them `svc-<role>`, e.g. `svc-xyz`. |
| **Topics you produce** | One per channel named in your specification (*Connection to Message Broker and channel used*). Name them `dnavio.<cmp>.<entity>.<qualifier>`, e.g. `dnavio.xyz.faults.detected`, and use the same names in the specification. Rate and size come from the specification's *Outputs*; add here only how long messages must be kept. |
| **Third-party credentials** | Names of keys your code needs from outside D-NAVIO (e.g. a weather API key). Only the names; you agree with the NTUA team how to send the values. |

The NTUA team takes everything else from the specification: hosting location,
containers and their resources, the topics you consume (from your *Inputs*),
and message formats (from *Format & example*).

**Example:**

```text
Component ID:       XYZ
Specification:      attached (D-NAVIO_Component&Interfaces_Specification_XYZ-ExampleInstitute.docx)
Technical contact:  Jane Doe, jane.doe@example.org
Repository:         D-NAVIO-Project/xyz

Identities — one per role: name — which containers use it
  - svc-xyz — xyz-inference-api, xyz-detector

Topics you produce — topic name — Output ID(s) — how long messages must be kept
  - dnavio.xyz.faults.detected — XYZ.out.01 — 30 days

Third-party credentials needed (names only, never values): none
Object storage (MinIO) needed: no
Notes:
```

### What happens next

The NTUA team reviews the request, then creates your identities, topics and
access rules, and replies by email with what you need for the next steps, for
example:

> Approved. Identity `svc-xyz`: use `credentials/svc-xyz-client-id` and
> `credentials/svc-xyz-client-secret` in your values file. Topics: you may
> produce to `dnavio.xyz.faults.detected` and consume
> `dnavio.dml.telemetry.normalized`. Memory budget: 512Mi. Reference the
> shared pipelines as `@main`.

Keep this reply at hand — the names in it go into your values file (A4) and
deploy pipeline (A6).

For a component **hosted at your premises**, the reply only confirms
approval; your credentials are sent separately, through a private channel
agreed with you.

**To change anything later** (a new topic, another identity, more memory),
reply to the same email thread, and update your specification to match.

---

## Path A — Hosted at NTUA

You will add three things to your repository, then push:

```
your-repository/
├── Dockerfile                    # A2 — how to build your container's image
├── ...                           #      your code
├── deploy/
│   ├── dnavio-values.yaml        # A4 — which containers run on the platform
│   └── infra/                    # A5 — only if you need persistent storage
└── .github/workflows/
    └── dnavio-deploy.yml         # A6 — the deploy pipeline
```

| Step | You do | You end up with |
|------|--------|-----------------|
| [A1](#a1-what-the-platform-gives-you) | Read what the platform provides | The addresses your code connects to |
| [A2](#a2-prepare-your-code) | Adapt your code and add a Dockerfile | An image that starts and answers a health check |
| [A3](#a3-using-platform-data) | Match your Inputs and Outputs to topics | Consumer and producer code with the right names |
| [A4](#a4-describe-your-containers-in-a-values-file) | Write `deploy/dnavio-values.yaml` | A description of your containers |
| [A5](#a5-your-own-chart-optional) | (Optional) add your own chart | A database or similar, next to your containers |
| [A6](#a6-add-the-deploy-pipeline) | Add `.github/workflows/dnavio-deploy.yml` | Automatic build and deploy on every push |
| [A7](#a7-deploy-verify-and-debug) | Push, then read the pipeline run | Running containers, a test message received |

You never need access to the platform's cluster: everything happens through
your repository and the pipeline runs in it.

### A1. What the platform gives you

| | |
|---|---|
| Message Broker | `kafka:9092` — security protocol `SASL_PLAINTEXT`, mechanism `OAUTHBEARER` |
| Token endpoint | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` |
| Your identities | In your values file as `credentials/<client>-client-id` and `credentials/<client>-client-secret` |
| Your own secrets | Secret `<cmp>-secrets`, in your values file as `partner/<key>` (e.g. third-party API keys, or your own database's connection string — see A5) |
| Your other containers | `http://<cmp>-<name>:<port>`, e.g. `http://xyz-inference-api:8080` |
| Object storage | MinIO, on request |
| Access from outside | Not by default: containers are reachable only inside the platform. If a container has its own UI or an API used from outside, say so in your specification and the NTUA team arranges access. |

Inside the platform no TLS certificate is needed: traffic stays on the
platform's internal network.

### A2. Prepare your code

#### 1. Read all settings from environment variables

Nothing that differs between environments may be hard-coded: broker address,
token endpoint, client id, client secret, topic names, group ids. You choose
the variable names; the values file (A4) sets them. A typical set:

| Variable (your choice of name) | Value on the platform | Set in A4 under |
|---|---|---|
| `KAFKA_BOOTSTRAP` | `kafka:9092` | `env` |
| `KAFKA_TOKEN_URL` | `http://keycloak:8080/realms/d-navio/protocol/openid-connect/token` | `env` |
| `KAFKA_CLIENT_ID` | your identity's client id | `secretEnv` |
| `KAFKA_CLIENT_SECRET` | your identity's client secret | `secretEnv` |
| `INPUT_TOPIC`, `OUTPUT_TOPIC` | e.g. `dnavio.dml.telemetry.normalized` | `env` |
| `KAFKA_GROUP_ID` | e.g. `xyz-detector` | `env` |

Read them with a clear error if one is missing, so a misconfigured deploy
fails at start-up with a readable message instead of later:

```python
import os

def setting(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"missing required environment variable {name}")
    return value
```

#### 2. Connect to Kafka with OAUTHBEARER

Your client fetches a token from Keycloak with its client id and secret, and
renews it before it expires. The Kafka libraries do the renewing; you only
supply a function that fetches a token.

**Python** (`pip install confluent-kafka requests`) — producer:

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

Always check the delivery result as above: a message Kafka refuses (for
example, on a topic your identity may not write) is reported only there.

Consumer (same `conf` and `fetch_token`):

```python
from confluent_kafka import Consumer

consumer = Consumer({
    **conf,
    "group.id": os.environ["KAFKA_GROUP_ID"],   # e.g. xyz-detector — see A3
    "auto.offset.reset": "earliest",            # first start: read from the oldest kept message
})
consumer.subscribe([os.environ["INPUT_TOPIC"]])

while True:
    msg = consumer.poll(1.0)
    if msg is None:
        continue
    if msg.error():
        print("consumer error:", msg.error())
        continue
    handle(msg.value())          # your processing; msg.value() is bytes
```

**Go** ([franz-go](https://github.com/twmb/franz-go)):

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
		// For a consumer, add:
		// kgo.ConsumerGroup(os.Getenv("KAFKA_GROUP_ID")),
		// kgo.ConsumeTopics(os.Getenv("INPUT_TOPIC")),
	)
}
```

**Java and other languages:** see the
[Kafka integration guide](kafka-partner-integration.md#6-code-examples), using
the values above (`SASL_PLAINTEXT`, no TLS, no CA certificate).

<a id="matching-your-triggers"></a>**Matching your triggers.** Each trigger
type in your specification maps to a way your code starts work:

| Trigger type in the specification | In your code |
|---|---|
| Event / message, Data arrival | A consumer loop on the topic (above) |
| API call | An HTTP endpoint; the container needs a `port` (A4) |
| Schedule | A timer in a long-running container, or a CronJob in your own chart (A5) |
| User action | Your UI or API calls the code; see *Access from outside* in A1 |

#### 3. Add a health check

**Containers with an HTTP port** — add a path that returns 200 when the
container works, e.g. in FastAPI:

```python
@app.get("/healthz")
def healthz():
    return {"status": "ok"}
```

If you can, also add a *readiness* path (e.g. `/readyz`) that returns 200 only
once the container has connected to what it needs (e.g. Kafka); the platform
then sends no traffic until it is ready.

How the platform uses them, so you know what your paths must do:

- **Readiness** is checked every 10 s. Until it returns 200, the container
  gets no traffic and the deploy keeps waiting (up to 5 minutes).
- **Liveness** is checked every 20 s, starting 15 s after start-up. After
  **3 failures in a row** the container is restarted. Keep this path fast
  (it must answer within 5 s) and independent of other components — if it
  failed whenever Kafka is briefly unreachable, your container would restart
  for no reason.

**Background workers without a port** — give a command that exits 0 when
healthy (`healthCommand` in A4). A simple pattern: the worker touches a file
on every loop, and the command checks the file is recent:

```python
import pathlib
heartbeat = pathlib.Path("/tmp/heartbeat")

while True:
    ...                  # one round of work, e.g. consumer.poll(...)
    heartbeat.touch()
```

```yaml
healthCommand: ["sh", "-c", "find /tmp/heartbeat -mmin -2 | grep -q ."]   # touched in the last 2 minutes
```

#### 4. Write a Dockerfile

One image per container. A typical Python container:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
# Listen on 0.0.0.0, not 127.0.0.1 — otherwise the health checks cannot reach it.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

If several containers share one code base, one Dockerfile can build all of
them with a build argument (`ARG SERVICE`, then e.g.
`CMD python -m "services.${SERVICE}"`); the pipeline passes it in A6. A
working reference is the platform's own test component:
[apps/test-producer](../apps/test-producer).

**Image / repository in your specification:** give your Git repository. The
deploy pipeline builds each image from it on the platform, named
`<cmp>/<container>` (e.g. `xyz/inference-api`) and tagged with the commit it
was built from. You don't publish images to a registry or choose version
tags.

#### 5. Test the image on your machine

Before pushing, check the image starts and answers its health check:

```bash
docker build -t xyz/inference-api .
```

```bash
docker run --rm -p 8080:8080 -e KAFKA_BOOTSTRAP=localhost:9092 -e KAFKA_TOKEN_URL=http://localhost/token -e KAFKA_CLIENT_ID=test -e KAFKA_CLIENT_SECRET=test xyz/inference-api
```

```bash
curl -i http://localhost:8080/healthz
```

Expect `HTTP/1.1 200 OK`. The platform's Message Broker is not reachable from
your machine, so connection errors in the log are expected here; what you are
checking is that the image starts, listens on the port and answers the health
path. While it runs, `docker stats` shows its memory use (`MEM USAGE`) — you
need that number in A4.

#### 6. Don't bundle platform services

No Kafka, Redpanda or Keycloak of your own — use the platform's Message
Broker and Keycloak. Remove them from any Docker Compose file you deploy
from, and point your code at the platform addresses in A1 instead.

### A3. Using platform data

Topics available today:

| Topic | Produced by | Contains | Kept for |
|-------|-------------|----------|----------|
| `dnavio.dml.telemetry.normalized` | T4.2 (DML) | Validated, normalised live pilot data — **the topic most consumers want** | 7 days |
| `dnavio.dml.telemetry.raw` | Pilot data sources (via T4.2 ingestion) | Live pilot data as received | 7 days |
| `dnavio.dml.deadletter` | T4.2 (DML) | Messages that failed validation | 30 days |
| `dnavio.frs.failures.reported` | T4.2 (FRS) | Failure records | Indefinitely |
| `dnavio.frs.hydra.probability-update` | T4.2 (FRS) | HYDRA root-node probability updates | 30 days |
| `dnavio.hydra.riskscores` | HYDRA | Risk scores | 7 days (broker default) |
| `dnavio.frs.incidents.cyber` | Cybersecurity toolkit | Cyber incidents | Indefinitely |

**What to do:**

1. **Inputs.** For each Input in your specification (`<CMP>.in.0X`):
   - *Live pilot data* or *D-NAVIO component output* → find the topic above
     (or the producing component's topic, from its specification). Your
     identity can only read the topics granted to it after Step 1.
   - *Historical pilot data* → see **History** below.
2. **Outputs.** For each Output (`<CMP>.out.0X`) that goes through the Message
   Broker, produce to the topic agreed in Step 1.
3. **Message formats.** Write your code against the contract — the producing
   component's *Format & example*, and for T4.2's topics its `contracts/` in
   `d-navio-t4.2` (ask the NTUA team for access) — not against a sample
   message. Keep your own Outputs' *Format & example* in the specification up
   to date: it is what your consumers code against.
4. **Consumer group ids.** For each consumer, choose a group id: your
   Component ID, then what the consumer does — `xyz-detector`. Set it as
   `group.id` (A2). Two consumers with the same group id split the messages
   between them; use a different id for each consumer that must see every
   message.
5. **Where a new consumer starts.** `auto.offset.reset: earliest` reads
   everything still kept in the topic; `latest` reads only messages produced
   from now on. This applies only the first time a group id is used — after
   that, Kafka continues from where the group stopped.

**History.** Topics keep data for a limited time (above), so the Message
Broker is not an archive. Historical pilot data is held by T4.2, which plans
to serve historical queries (time windows, exports) through its query
service. If you need history, mark the Input as *Historical Pilot Data* in
your specification and mention it in your request. Do not connect to the
platform databases directly.

### A4. Describe your containers in a values file

Create `deploy/dnavio-values.yaml` in your repository — one entry per
*internal container / pod* in your specification. Start from this example and
change it as described below:

```yaml
partner: xyz                          # your Component ID, in lowercase
components:                           # one entry per container
  - name: inference-api               # runs as xyz-inference-api
    image: xyz/inference-api          # <cmp>/<name>; no tag — the pipeline adds it
    port: 8080                        # "Exposed ports / endpoints"
    health: { readiness: /readyz, liveness: /healthz }
    memory: 256Mi                     # "Resources — RAM"; see "Choosing memory"
    env:                              # plain settings, visible in your repository
      KAFKA_BOOTSTRAP: kafka:9092
      KAFKA_TOKEN_URL: http://keycloak:8080/realms/d-navio/protocol/openid-connect/token
      OUTPUT_TOPIC: dnavio.xyz.faults.detected
      LOG_LEVEL: info
    secretEnv:                        # credentials, injected from the platform
      KAFKA_CLIENT_ID: credentials/svc-xyz-client-id
      KAFKA_CLIENT_SECRET: credentials/svc-xyz-client-secret

  - name: detector                    # a background worker: no port
    image: xyz/detector
    healthCommand: ["sh", "-c", "find /tmp/heartbeat -mmin -2 | grep -q ."]
    memory: 128Mi
    env:
      KAFKA_BOOTSTRAP: kafka:9092
      KAFKA_TOKEN_URL: http://keycloak:8080/realms/d-navio/protocol/openid-connect/token
      INPUT_TOPIC: dnavio.dml.telemetry.normalized
      KAFKA_GROUP_ID: xyz-detector
      INFERENCE_URL: http://xyz-inference-api:8080   # calling your other container
    secretEnv:
      KAFKA_CLIENT_ID: credentials/svc-xyz-client-id
      KAFKA_CLIENT_SECRET: credentials/svc-xyz-client-secret
```

**How to fill it in:**

1. Set `partner` to your Component ID in lowercase.
2. Add one entry under `components` per container. Its `name` is the
   Container / Pod ID from your specification without the prefix:
   `xyz-inference-api` → `inference-api`.
3. For each, set `image` (`<cmp>/<name>`) and `memory`.
4. Containers with an HTTP port: set `port` and `health`. Workers: leave out
   `port` and set `healthCommand`.
5. Under `env`, set every variable your code reads (A2.1) that is not a
   credential.
6. Under `secretEnv`, map your credential variables to the names in the NTUA
   reply: `credentials/<client>-client-id` and
   `credentials/<client>-client-secret`.

| Field | What to put |
|-------|-------------|
| `partner` | Your Component ID, lowercase. |
| `name` | The container name, lowercase with hyphens. It runs as `<cmp>-<name>` — the Container / Pod ID in your specification; other containers reach it at `http://<cmp>-<name>:<port>`. |
| `image` | `<cmp>/<name>` — must match the `image` your deploy pipeline builds (A6). Never a tag: each push is built and deployed with the commit id as its tag. |
| `port` | The port your container listens on (*Exposed ports / endpoints*). Omit for background workers (then give `healthCommand`, a command that exits 0 when healthy). |
| `health` | One path for both checks (`health: /healthz`), or `{readiness: ..., liveness: ...}`. |
| `healthCommand` | Workers only: the command run inside the container, as a list. |
| `memory` | *Resources — RAM*. Request **and** limit. If your container uses more, it is restarted (`OOMKilled`). |
| `env` | Non-secret settings. **Variable names are your application's own** — whatever A2 reads. |
| `secretEnv` | Credentials: `VARIABLE: <alias>/<key>`, with the aliases `credentials/...` (your identities) and `partner/...` (your component's own Secret). Anything named like `*PASSWORD*`, `*SECRET*`, `*TOKEN*` must go here — the deploy refuses it in `env`. Names ending in `_URL`, `_URI`, `_ENDPOINT`, `_PATH` or `_FILE` (e.g. `KAFKA_TOKEN_URL`) are addresses, not credentials, and go in `env`. |
| `cpu` | *Resources — Cores*, optional, as a CPU request: `500m` is half a core, `1` one core. |
| `replicas` | Optional, default 1. More than one only if your container can run as several copies (consumers in one group share the topic's partitions). |
| `command`, `args` | Optional: override the image's `ENTRYPOINT` / `CMD`. |

<a id="choosing-memory"></a>**Choosing memory** (*Resources — RAM* in your
specification):

1. Run the image locally (A2.5) and give it realistic work — a burst of
   requests, or a batch of messages.
2. Read the highest `MEM USAGE` in `docker stats`.
3. Add ~50% and round up: e.g. 140 MiB measured → `memory: 256Mi`.

Typical starting points: Go 64Mi, Python/Node.js 128–256Mi, Java (JVM) 512Mi
or more (and limit the heap, e.g. `-XX:MaxRAMPercentage=75`). The sum over
all your containers must stay within the budget in the NTUA reply; to get
more, reply to your onboarding thread.

**Check the values file before pushing** (optional, needs
[Helm](https://helm.sh/docs/intro/install/)). Clone the platform repository
once, then render your file with the platform's component chart:

```bash
git clone https://github.com/D-NAVIO-Project/d-navio-platform.git
```

```bash
helm template xyz d-navio-platform/helm/dnavio-component -f deploy/dnavio-values.yaml --set image.tag=test
```

You either get the Kubernetes resources that will be created, or the same
refusal message the deploy would give you — naming the container and field
to fix. The deploy is refused if the values file bundles a platform service
or a database, misses memory or a health check, pins an image tag, or puts a
credential in `env`.

Full reference:
[helm/dnavio-component/README.md](../helm/dnavio-component/README.md); a
complete six-container example:
[examples/t42-values.yaml](../helm/dnavio-component/examples/t42-values.yaml).

### A5. Your own chart (optional)

Only needed for something the component chart cannot run — a container with
*Persistent storage* in your specification, typically a database (as for
T4.2's datastores), or a scheduled job. Most components skip this step.

**What to do:**

1. Copy the reference chart
   [examples/infra-chart](../helm/dnavio-component/examples/infra-chart) to
   `deploy/infra` in your repository. It runs one PostgreSQL. You don't need
   to rename anything: every resource name is derived from your Component ID.
2. Adjust `deploy/infra/values.yaml` — memory, storage, database and user
   name:

   ```yaml
   postgres:
     image: postgres:16-alpine
     username: app
     database: app
     memory: 512Mi
     storage: 8Gi
   ```

3. (Optional) To create tables on first start, add `.sql` or `.sh` files to
   `deploy/infra/initdb/`. They run **once**, when the database is first
   created — later changes to them have no effect on an existing database.
4. In your values file, give the containers that use the database its
   connection string:

   ```yaml
       secretEnv:
         DATABASE_URL: partner/postgres-dsn
   ```

   The chart generates a password on first install and stores it, with a
   ready-made connection string
   (`postgres://app:<password>@<cmp>-postgres:5432/app?sslmode=disable`), in
   your Secret `<cmp>-secrets`. You never see or handle the password. The
   database is reachable inside the platform as `<cmp>-postgres:5432`.
5. In your deploy pipeline (A6), uncomment `chart: deploy/infra`.

Your chart is deployed as release `<cmp>-infra`, **before** your containers,
so the database exists when your containers start.

**Check it before pushing** (optional, needs Helm and Python with
`pyyaml`, and the platform clone from A4):

```bash
helm template xyz-infra deploy/infra > own.yaml
```

```bash
python3 d-navio-platform/scripts/partner-policy/check_partner_chart.py xyz dnavio-dev own.yaml
```

The deploy runs the same check, and is refused if your chart:

- creates anything not named `<cmp>-...`, or in another namespace;
- creates kinds other than Deployment, StatefulSet, Job, CronJob, Service,
  ConfigMap, Secret, PersistentVolumeClaim (permissions and cluster-wide
  resources stay with the NTUA team);
- exposes a Service outside the platform (only `ClusterIP`);
- misses a memory limit on any container;
- uses host networking, host paths or privileged containers;
- runs a platform service image (Kafka, Keycloak, MinIO);
- puts a credential in a plain environment variable (use
  `valueFrom.secretKeyRef`, as the reference chart does).

### A6. Add the deploy pipeline

Create `.github/workflows/dnavio-deploy.yml` in your repository. This GitHub
Actions workflow builds an image for each container and deploys them on every
push to `main`, and can be started by hand from the Actions tab:

```yaml
name: Deploy to D-NAVIO
on:
  push:
    branches: [main]
  workflow_dispatch:            # adds a "Run workflow" button

permissions:
  contents: read

jobs:
  build:                        # one image per container, built on the platform
    strategy:
      max-parallel: 1           # one shared build machine
      matrix:
        container: [inference-api, detector]
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/build-component.yml@main
    with:
      partner: xyz                       # your Component ID, lowercase
      image: ${{ matrix.container }}     # built as xyz/<container>
      dockerfile: Dockerfile             # path in your repository
      build-args: SERVICE=${{ matrix.container }}   # only if one Dockerfile builds several containers

  deploy:
    needs: build
    uses: D-NAVIO-Project/d-navio-platform/.github/workflows/deploy-component.yml@main
    with:
      partner: xyz
      values: deploy/dnavio-values.yaml
      # chart: deploy/infra             # only with your own chart (A5)
      environment: dev
      logs: true                         # print startup logs after deploying
```

**What to change:**

1. Replace `xyz` (twice) with your Component ID in lowercase.
2. List your containers under `matrix.container` — the same names as `name`
   in your values file.
3. Point `dockerfile` at your Dockerfile, and pick the variant that matches
   your repository:

   - **One Dockerfile per container, in sub-folders** (e.g.
     `services/inference-api/Dockerfile`):

     ```yaml
         dockerfile: services/${{ matrix.container }}/Dockerfile
         context: services/${{ matrix.container }}   # folder the Dockerfile's COPY paths are relative to
     ```

   - **One Dockerfile for all containers:** keep `dockerfile: Dockerfile` and
     the `build-args` line.
   - **A single container:** replace the `strategy`/`matrix` block with
     `image: inference-api` and remove `build-args`.

4. With your own chart (A5), uncomment `chart: deploy/infra`.
5. Use the version the NTUA reply gives you in place of `@main`, if it gives
   one.

| `build` input | Meaning | Default |
|---|---|---|
| `partner` | Your Component ID, lowercase | required |
| `image` | Container name; the image is `<cmp>/<image>` | required |
| `dockerfile` | Path to the Dockerfile | `Dockerfile` |
| `context` | Folder sent to the build | `.` (repository root) |
| `build-args` | `KEY=VALUE`, one per line | none |

| `deploy` input | Meaning | Default |
|---|---|---|
| `partner` | Your Component ID, lowercase | required |
| `values` | Your values file (A4) | none |
| `chart` | Your own chart folder (A5) | none |
| `chart-values` | An extra values file for your own chart | none |
| `environment` | `dev` or `pilot` | `dev` |
| `timeout` | How long to wait for your containers to become ready | `5m` |
| `logs` | Print each container's recent logs after a successful deploy | `false` |

### A7. Deploy, verify and debug

**First deploy:**

1. Commit the files from A2–A6 and push to `main`.
2. In your repository on GitHub, open **Actions → Deploy to D-NAVIO** and
   click the newest run. It shows one *build* job per container, then
   *deploy*.
3. Wait for it to finish (a few minutes; builds run one at a time on a shared
   machine, so a run may also wait for other components' builds).

**Reading the result:**

- **Green run**: the run's summary page lists your containers' pods as
  `Running`. With `logs: true`, open the *deploy* job and expand *Pod logs* to
  see each container's startup — check that it connected to Kafka without
  errors.
- **Red run**: open the job with the red mark and the step that failed.
  - A rule violation (e.g. `components.detector: memory is required`) names
    the field to fix.
  - If a pod did not start, expand the *Diagnostics* groups: the pod's events
    say why it was not scheduled or not ready, and its logs (including the
    logs from before the last restart) show crashes.
  - See [Troubleshooting](#troubleshooting) for common messages.
- **End-to-end check**: produce one test message to a topic you own and
  confirm that your consumer (or the consuming component) receives it. Only
  then is the integration done.

**Afterwards:**

| To... | Do this |
|-------|---------|
| Deploy a change | Push to `main`. Every push rebuilds and redeploys. |
| Re-run without a change | Actions → Deploy to D-NAVIO → **Run workflow**, or **Re-run jobs** on an existing run. |
| Undo a bad change | `git revert <commit>` and push; the previous version is rebuilt and deployed. |
| Remove a container | Delete its entry from the values file and from `matrix.container`, then push. Update your specification too. |
| Change memory, topics or identities beyond what was agreed | Reply to your onboarding email thread first. |
| Deploy to `pilot` | Only once agreed with the NTUA team; they will tell you when to add a deploy job with `environment: pilot`. |

You do not need access to the platform's cluster: everything is visible in
the pipeline run. **If your repository is public, so are these logs** — never
print credentials from your code.

### A8. Checklist

- [ ] Specification sent; request approved; identities, topics and budget in the NTUA reply
- [ ] Settings read from environment variables
- [ ] Kafka client uses OAUTHBEARER and checks delivery errors
- [ ] Health check (path or `healthCommand`) in every container
- [ ] Image builds and answers its health check locally
- [ ] `deploy/dnavio-values.yaml` added, one entry per container in the specification
- [ ] Deploy pipeline added; image names match the values file; first run green
- [ ] Test message produced and received

---

## Path B — Hosted at your premises

Your containers run in your own environment and connect to the platform over
the network.

**1. Receive your credentials.** Once your request is approved, the NTUA team
sends you, through a private channel agreed with you (never in the onboarding
email thread):

- your client id and client secret;
- the D-NAVIO CA certificate, `ca.crt`;
- the platform endpoints: the broker address (`<broker>`) and the Keycloak
  base URL (`<keycloak>`).

**2. Store them safely.** Keep the client secret where your environment keeps
secrets (a Kubernetes Secret, a vault, an environment variable on the server)
— never in your repository or in code. For Kubernetes, see the
[Kafka integration guide, section 5](kafka-partner-integration.md#5-deploying-in-your-own-kubernetes-cluster).

**3. Check your network reaches both endpoints** from the machine your
containers will run on — commands in the
[Kafka integration guide, section 2](kafka-partner-integration.md#2-network-requirements).
If they time out, ask your network team to allow outgoing connections to both
addresses.

**4. Fetch a token by hand** to confirm your credentials work:

```bash
curl -s --cacert ca.crt -X POST <keycloak>/realms/d-navio/protocol/openid-connect/token -d grant_type=client_credentials -d client_id=<your client id> -d client_secret=<your client secret>
```

A JSON answer with an `access_token` means it works; `invalid_client` means
the id or secret is wrong.

**5. Configure your Kafka client** with these settings:

| Setting | Value |
|---------|-------|
| Bootstrap server | `<broker>` |
| Security protocol | `SASL_SSL` |
| SASL mechanism | `OAUTHBEARER` |
| Token endpoint | `<keycloak>/realms/d-navio/protocol/openid-connect/token` |
| Trusted CA | `ca.crt` (in `confluent-kafka`: `ssl.ca.location`) |

The code in [A2](#2-connect-to-kafka-with-oauthbearer) works unchanged apart
from two settings:

```python
conf = {
    "bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],   # <broker>
    "security.protocol": "SASL_SSL",
    "ssl.ca.location": os.environ["KAFKA_CA_FILE"],       # path to ca.crt
    "sasl.mechanism": "OAUTHBEARER",
    "oauth_cb": fetch_token,
}
```

and `requests.post(..., verify=os.environ["KAFKA_CA_FILE"])` in
`fetch_token`. Java and other languages: see the
[Kafka integration guide, section 6](kafka-partner-integration.md#6-code-examples).
Never switch off certificate verification.

**6. Test end to end:** produce one message to a topic you own and consume it
back (or ask the consuming component's team to confirm they received it).

**7. Browser login for your users** (if your component has its own UI): see
the [SSO integration guide](sso-partner-integration.md).

[A3](#a3-using-platform-data) — matching Inputs and Outputs to topics, and
consumer group ids — applies to you as well.

---

## Troubleshooting

| You see | Likely cause | Fix |
|---------|--------------|-----|
| Deploy refused: `components.<name>: ...` | The values file breaks a rule | Do what the message says (add `memory`, move a variable to `secretEnv`, ...) |
| Deploy refused: `<Kind>/<name>: ...` (own chart) | Your own chart breaks a rule | Fix the resource named in the message — see A5 |
| `image <cmp>/<x> has not been built` | The build job did not build it for this commit, or the names differ | Make the pipeline's `image:` and the values file's `image:` match |
| Build fails at `COPY` | A path in the Dockerfile is not inside `context` | Set `context` to the folder the `COPY` paths are relative to (A6) |
| Pod `CreateContainerConfigError` | A `secretEnv` key does not exist | Check the key against the NTUA reply; for `partner/...`, check your own chart creates it |
| Pod not ready, restarting | Health path or port wrong, the container listens on `127.0.0.1`, or it crashes on start | Check the logs in *Diagnostics*; check `port`, `health` and that the container listens on `0.0.0.0` |
| `OOMKilled` | The container needs more memory | Raise `memory` (within your budget) |
| Run waits a long time before *build* starts | Other components' builds are running | Wait; builds run one at a time |
| Kafka: `SASL authentication failed` / invalid token | Wrong client id/secret mapping or token URL | Check `secretEnv` and the token endpoint variable |
| Kafka: `TOPIC_AUTHORIZATION_FAILED` | Your identity may not write to that topic | Request it from the NTUA team (reply to your onboarding thread) |
| Kafka: `UNKNOWN_TOPIC_OR_PARTITION` | The topic does not exist | Request it from the NTUA team (reply to your onboarding thread) |
| Consumer receives nothing | Group already read to the end, or nothing produced yet | Check the group id; produce a test message |
| `workflow was not found` | Wrong `@ref` for the shared pipelines | Use the ref the NTUA team gave you |

Still stuck? Email the NTUA team with a link to the failed run.

---

## Rules at a glance

| Do | Don't |
|---|---|
| Use the platform's Message Broker (Kafka) and Keycloak | Run your own Kafka, Redpanda or Keycloak |
| Get data through topics; ask T4.2 for historical pilot data | Connect to the platform databases directly |
| Prefix everything with your Component ID | Use generic names (`api`, `postgres`, `consumer`) |
| Keep credentials in `secretEnv` | Put credentials in values files, the specification, emails or code |
| Set memory and health checks | Deploy without limits — the platform is shared |
| Name topics `dnavio.<cmp>.<entity>.<qualifier>` | Write to topics you have not requested |
| Request changes by email to the NTUA team, and keep your specification current | Change platform resources yourself |

---

*Questions: email the NTUA team at `<NTUA contact email>`.*
