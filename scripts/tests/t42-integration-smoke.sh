#!/usr/bin/env bash
# Smoke test for the platform services that T4.2 (DML/FRS) depends on.
#
# Exercises the same paths a T4.2 pod uses — from throwaway pods inside the
# namespace, reading credentials only from the platform Secrets:
#   - Postgres via the postgres-dsn connection string (auth, T4.2 schema, write)
#   - Mongo via the mongo-uri connection string (auth, collections, write,
#     least privilege)
#   - Kafka on kafka:9092 (SASL_PLAINTEXT / OAUTHBEARER) as svc-dml and
#     svc-frs, including an ACL denial on the admin-restricted topic
# plus deployment health, hook Jobs, memory limits, Secrets, topics, retention.
#
# Leaves no data behind: Kafka traffic goes to a temporary topic, Postgres uses
# a temp table, Mongo a scratch collection — all removed at the end.
#
# Usage: scripts/tests/t42-integration-smoke.sh [namespace]   (default dnavio-dev)
# Needs kubectl with admin access to the namespace. Exits 1 if any check fails.

set -uo pipefail

NS="${1:-dnavio-dev}"
REALM="${REALM:-d-navio}"
RUN_ID="$(date +%s)"
TOPIC="dnavio.smoke.${RUN_ID}"
PASSED=0
FAILED=0
FAILURES=()
WORK="$(mktemp -d)"
KAFKA_IMAGE="$(kubectl get deploy kafka -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
KAFKA_IMAGE="${KAFKA_IMAGE:-confluentinc/cp-kafka:7.8.3}"

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); FAILURES+=("$1"); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n== %s ==\n' "$1"; }

# Loopback BROKER listener: PLAINTEXT, broker super-user. Admin tasks only.
kafka_admin() {
  kubectl exec -n "$NS" deploy/kafka -c kafka -- "$@" 2>/dev/null
}

cleanup() {
  kubectl delete pod -n "$NS" -l "dnavio.smoke/run=${RUN_ID}" \
    --ignore-not-found --wait=false >/dev/null 2>&1
  kafka_admin kafka-topics --bootstrap-server 127.0.0.1:9091 \
    --delete --topic "$TOPIC" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

# Fill the placeholders of a pod manifest read from stdin.
render() {
  sed -e "s|__NAME__|$1|g" -e "s|__CLIENT__|${2:-}|g" -e "s|__NEGATIVE__|${3:-0}|g" \
      -e "s|__RUN__|${RUN_ID}|g" -e "s|__TOPIC__|${TOPIC}|g" \
      -e "s|__REALM__|${REALM}|g" -e "s|__KAFKA_IMAGE__|${KAFKA_IMAGE}|g"
}

# run_pod NAME < manifest-file — waits for the pod to finish and relays its
# "CHECK PASS|FAIL <text>" and "INFO <text>" lines.
run_pod() {
  local name="$1" phase="" waited=0 logs line saw_fail=0
  if ! kubectl apply -n "$NS" -f - >/dev/null; then
    fail "$name: pod could not be created"
    return
  fi
  while [ "$waited" -lt 300 ]; do
    phase="$(kubectl get pod "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 3
    waited=$((waited + 3))
  done
  logs="$(kubectl logs "$name" -n "$NS" 2>&1)"
  while IFS= read -r line; do
    case "$line" in
      "CHECK PASS "*) pass "${line#CHECK PASS }" ;;
      "CHECK FAIL "*) fail "${line#CHECK FAIL }"; saw_fail=1 ;;
      "INFO "*) printf '        %s\n' "${line#INFO }" ;;
    esac
  done <<< "$logs"
  if [ "$phase" != "Succeeded" ] && [ "$saw_fail" -eq 0 ]; then
    fail "$name: pod ended in phase '${phase:-timeout}' (last log lines below)"
    printf '%s\n' "$logs" | tail -15 | sed 's/^/        /'
  fi
}

printf 'T4.2 integration smoke test — namespace %s, run %s\n' "$NS" "$RUN_ID"

# ---------------------------------------------------------------------------
section "Deployments ready"
for d in keycloak kafka minio postgres mongo; do
  if kubectl rollout status "deployment/$d" -n "$NS" --timeout=120s >/dev/null 2>&1; then
    pass "$d rolled out and ready"
  else
    fail "$d is not ready"
  fi
done

section "Hook jobs completed"
for j in keycloak-realm-bootstrap kafka-topics-init kafka-acls-init; do
  if [ "$(kubectl get job "$j" -n "$NS" -o jsonpath='{.status.succeeded}' 2>/dev/null)" = "1" ]; then
    pass "$j succeeded"
  else
    fail "$j has not succeeded (kubectl logs job/$j -n $NS)"
  fi
done

section "Memory limits"
for d in keycloak kafka minio postgres mongo; do
  lim="$(kubectl get deploy "$d" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
  if [ -n "$lim" ]; then pass "$d limited to $lim"; else fail "$d has no memory limit"; fi
done

section "Secrets (keys only — values are never printed)"
check_keys() {
  local secret="$1"; shift
  local keys k
  keys=" $(kubectl get secret "$secret" -n "$NS" \
    -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>/dev/null) "
  for k in "$@"; do
    case "$keys" in
      *" $k "*) pass "$secret has $k" ;;
      *) fail "$secret is missing $k" ;;
    esac
  done
}
check_keys dnavio-datastores postgres-dsn mongo-uri
check_keys dnavio-component-credentials svc-dml-client-id svc-dml-client-secret \
  svc-frs-client-id svc-frs-client-secret

section "Topics and retention"
topics="$(kafka_admin kafka-topics --bootstrap-server 127.0.0.1:9091 --list)"
for t in dnavio.dml.telemetry.raw dnavio.dml.telemetry.normalized dnavio.dml.deadletter \
         dnavio.frs.failures.reported dnavio.frs.hydra.probability-update \
         dnavio.hydra.riskscores dnavio.frs.incidents.cyber dnavio.ops.admin-audit; do
  # Capture-then-match, never `cmd | grep -q`: grep -q exits at the first
  # match, the writer gets SIGPIPE, and pipefail turns a match into a failure.
  if grep -qx "$t" <<< "$topics"; then pass "topic $t exists"; else fail "topic $t missing"; fi
done
check_config() {
  local cfg
  cfg="$(kafka_admin kafka-configs --bootstrap-server 127.0.0.1:9091 --describe \
           --entity-type topics --entity-name "$1")"
  case "$cfg" in
    *"$2"*) pass "$1 has $2" ;;
    *) fail "$1 lacks $2" ;;
  esac
}
check_config dnavio.dml.telemetry.raw retention.bytes=536870912
check_config dnavio.frs.failures.reported retention.ms=-1

# ---------------------------------------------------------------------------
section "Postgres, as a component would connect (postgres-dsn -> postgres:5432)"
render "smoke-pg-${RUN_ID}" > "$WORK/pg.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: __NAME__
  labels:
    dnavio.smoke/run: "__RUN__"
spec:
  restartPolicy: Never
  enableServiceLinks: false
  activeDeadlineSeconds: 240
  containers:
    - name: check
      image: postgres:16-alpine
      imagePullPolicy: IfNotPresent
      env:
        - name: PG_DSN
          valueFrom:
            secretKeyRef:
              name: dnavio-datastores
              key: postgres-dsn
      command:
        - /bin/sh
        - -c
        - |
          rc=0
          if who=$(psql "$PG_DSN" -qtAc "select current_user" 2>&1); then
            echo "CHECK PASS postgres: authenticated via postgres-dsn through the Service (user $who)"
          else
            echo "CHECK FAIL postgres: cannot connect via postgres-dsn: $who"
            exit 1
          fi
          n=$(psql "$PG_DSN" -qtAc "select count(*) from information_schema.tables where table_schema='dnavio'" 2>&1)
          if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
            echo "CHECK PASS postgres: T4.2 schema loaded ($n tables/views in schema dnavio)"
            echo "INFO $(psql "$PG_DSN" -qtAc "select string_agg(table_name, ', ' order by table_name) from information_schema.tables where table_schema='dnavio'")"
          else
            echo "CHECK FAIL postgres: T4.2 schema missing (got: $n)"
            rc=1
          fi
          rt=$(psql "$PG_DSN" -qtA -v ON_ERROR_STOP=1 \
                 -c "create temp table smoke(v text)" \
                 -c "insert into smoke values ('roundtrip')" \
                 -c "select v from smoke" 2>&1)
          case "$rt" in
            *roundtrip*) echo "CHECK PASS postgres: write/read round trip (temp table)" ;;
            *) echo "CHECK FAIL postgres: write/read failed: $rt"; rc=1 ;;
          esac
          exit $rc
YAML

run_pod "smoke-pg-${RUN_ID}" < "$WORK/pg.yaml"

section "Mongo, as a component would connect (mongo-uri -> mongo:27017)"
render "smoke-mongo-${RUN_ID}" > "$WORK/mongo.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: __NAME__
  labels:
    dnavio.smoke/run: "__RUN__"
spec:
  restartPolicy: Never
  enableServiceLinks: false
  activeDeadlineSeconds: 240
  containers:
    - name: check
      image: mongo:7.0
      imagePullPolicy: IfNotPresent
      env:
        - name: MONGO_URI
          valueFrom:
            secretKeyRef:
              name: dnavio-datastores
              key: mongo-uri
      command:
        - /bin/sh
        - -c
        - |
          cat > /tmp/smoke.js <<'JS'
          var failed = false;
          function check(ok, msg) {
            print((ok ? 'CHECK PASS ' : 'CHECK FAIL ') + 'mongo: ' + msg);
            if (!ok) { failed = true; }
          }
          check(db.getName() === 'dnavio',
                'authenticated via mongo-uri as the app user (database ' + db.getName() + ')');
          var cols = db.getCollectionNames();
          var want = ['iot_raw_event', 'failure_evidence', 'incident_metadata', 'deadletter'];
          var missing = want.filter(function (c) { return cols.indexOf(c) < 0; });
          check(missing.length === 0, missing.length === 0
                ? 'T4.2 collections present (' + want.join(', ') + ')'
                : 'T4.2 collections missing: ' + missing.join(', '));
          var id = db.smoke_test.insertOne({ at: new Date() }).insertedId;
          check(db.smoke_test.findOne({ _id: id }) !== null, 'write/read round trip (scratch collection)');
          db.smoke_test.drop();
          var denied = false;
          try {
            db.getSiblingDB('dnavio_smoke_forbidden').probe.insertOne({ a: 1 });
            db.getSiblingDB('dnavio_smoke_forbidden').dropDatabase();
          } catch (e) {
            denied = /not authorized|unauthorized/i.test(String(e));
          }
          check(denied, 'least privilege: writing to another database is refused');
          if (failed) { quit(1); }
          JS
          mongosh "$MONGO_URI" --quiet /tmp/smoke.js
YAML

run_pod "smoke-mongo-${RUN_ID}" < "$WORK/mongo.yaml"

# ---------------------------------------------------------------------------
section "Kafka, as T4.2 would connect (OAUTHBEARER on kafka:9092)"
if kafka_admin kafka-topics --bootstrap-server 127.0.0.1:9091 --create \
     --topic "$TOPIC" --partitions 1 --replication-factor 1 >/dev/null; then
  printf '        temporary topic %s (deleted at the end)\n' "$TOPIC"
else
  fail "could not create temporary topic $TOPIC"
fi

kafka_pod() {
  # kafka_pod CLIENT NEGATIVE — NEGATIVE=1 also asserts the ACL denial.
  local name="smoke-kafka-${1#svc-}-${RUN_ID}"
  render "$name" "$1" "$2" > "$WORK/$name.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: __NAME__
  labels:
    dnavio.smoke/run: "__RUN__"
spec:
  restartPolicy: Never
  enableServiceLinks: false
  activeDeadlineSeconds: 240
  containers:
    - name: check
      image: __KAFKA_IMAGE__
      imagePullPolicy: IfNotPresent
      env:
        - name: CLIENT_ID
          valueFrom:
            secretKeyRef:
              name: dnavio-component-credentials
              key: __CLIENT__-client-id
        - name: CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: dnavio-component-credentials
              key: __CLIENT__-client-secret
      command:
        - /bin/bash
        - -c
        - |
          cat > /tmp/client.properties <<EOF
          security.protocol=SASL_PLAINTEXT
          sasl.mechanism=OAUTHBEARER
          sasl.login.callback.handler.class=org.apache.kafka.common.security.oauthbearer.secured.OAuthBearerLoginCallbackHandler
          sasl.oauthbearer.token.endpoint.url=http://keycloak:8080/realms/__REALM__/protocol/openid-connect/token
          sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required clientId="${CLIENT_ID}" clientSecret="${CLIENT_SECRET}" ;
          EOF
          limits=(--producer-property max.block.ms=20000 --producer-property delivery.timeout.ms=30000
                  --producer-property request.timeout.ms=15000)
          rc=0
          marker="smoke-${CLIENT_ID}-__RUN__"
          out=$(echo "$marker" | kafka-console-producer --bootstrap-server kafka:9092 \
                  --producer.config /tmp/client.properties --topic __TOPIC__ "${limits[@]}" 2>&1)
          if echo "$out" | grep -q 'Exception'; then
            echo "CHECK FAIL kafka[${CLIENT_ID}]: produce failed: $(echo "$out" | grep 'Exception' | head -2 | tr '\n' ' ')"
            rc=1
          else
            echo "CHECK PASS kafka[${CLIENT_ID}]: Keycloak token accepted, produced over kafka:9092"
          fi
          got=$(kafka-console-consumer --bootstrap-server kafka:9092 \
                  --consumer.config /tmp/client.properties --topic __TOPIC__ --from-beginning \
                  --max-messages 10 --timeout-ms 20000 --group "smoke-${CLIENT_ID}-__RUN__" 2>&1)
          if echo "$got" | grep -q "$marker"; then
            echo "CHECK PASS kafka[${CLIENT_ID}]: consumed its own message back (consumer group)"
          else
            echo "CHECK FAIL kafka[${CLIENT_ID}]: own message not consumed: $(echo "$got" | grep 'Exception' | head -2 | tr '\n' ' ')"
            rc=1
          fi
          if [ "__NEGATIVE__" = "1" ]; then
            deny=$(echo "must-be-denied" | kafka-console-producer --bootstrap-server kafka:9092 \
                     --producer.config /tmp/client.properties --topic dnavio.ops.admin-audit "${limits[@]}" 2>&1)
            if echo "$deny" | grep -qE 'TopicAuthorizationException|TOPIC_AUTHORIZATION_FAILED|Not authorized'; then
              echo "CHECK PASS kafka[${CLIENT_ID}]: ACL enforced, write to dnavio.ops.admin-audit denied as User:${CLIENT_ID}"
            else
              echo "CHECK FAIL kafka[${CLIENT_ID}]: write to the admin-only topic was NOT denied"
              rc=1
            fi
          fi
          exit $rc
YAML
  run_pod "$name" < "$WORK/$name.yaml"
}
kafka_pod svc-dml 1
kafka_pod svc-frs 0

# ---------------------------------------------------------------------------
printf '\n== Result: %d passed, %d failed ==\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
