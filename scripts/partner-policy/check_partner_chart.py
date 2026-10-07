#!/usr/bin/env python3
"""Check a partner's own Helm chart (rendered) against the platform rules.

Partners deploy their services through helm/dnavio-component, which enforces
the rules by construction. Anything that chart cannot express (typically a
partner's own datastores) comes from the partner's own chart instead. Those
manifests are rendered with `helm template` and checked here before install.

Usage: check_partner_chart.py <partner> <namespace> <rendered.yaml>
Exits 1 and lists every violation if the manifests break a rule.
"""
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("::error::python3-yaml is required on the runner (apt install python3-yaml)")

# Namespaced kinds a partner chart may create. Anything cluster-scoped, or
# anything that grants permissions (Role, RoleBinding, ServiceAccount tokens),
# stays with the NTUA team.
ALLOWED_KINDS = {
    "Deployment", "StatefulSet", "Job", "CronJob",
    "Service", "ConfigMap", "Secret", "PersistentVolumeClaim",
}
# Platform services: use the platform's, never your own.
PLATFORM_IMAGES = {"kafka", "cp-kafka", "cp-server", "redpanda", "zookeeper", "keycloak", "minio"}
CREDENTIAL_LIKE = re.compile(r"(?i)(password|passwd|secret|token|api_?key|private_?key)")
# Names like KAFKA_TOKEN_URL are locations, not secrets.
LOCATION_NAME = re.compile(r"(?i)_(URL|URI|ENDPOINT|PATH|FILE)$")
# A password embedded in a URL (scheme://user:pass@host) is a secret whatever
# the variable is called.
URL_WITH_PASSWORD = re.compile(r"://[^/@\s]+:[^/@\s]+@")


def pod_spec(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "Job"):
        return (spec.get("template") or {}).get("spec") or {}
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    return None


UNIT_BYTES = {"": 1, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
              "Ki": 2 ** 10, "Mi": 2 ** 20, "Gi": 2 ** 30, "Ti": 2 ** 40}


def to_mib(quantity):
    """Kubernetes quantity (e.g. 512Mi, 1G, 8Gi) -> MiB. Unparseable -> 0."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?", str(quantity).strip())
    if not m:
        return 0.0
    return float(m.group(1)) * UNIT_BYTES[m.group(2) or ""] / 2 ** 20


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    partner, namespace, path = sys.argv[1:]
    prefix = partner + "-"
    with open(path, encoding="utf-8") as f:
        docs = [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]

    errors = []
    memory_mib = 0.0
    storage_mib = 0.0

    def err(where, msg):
        errors.append(f"{where}: {msg}")

    if not docs:
        errors.append("the chart rendered no resources")

    for doc in docs:
        kind = doc.get("kind", "?")
        meta = doc.get("metadata") or {}
        name = meta.get("name", "")
        where = f"{kind}/{name}"

        if kind not in ALLOWED_KINDS:
            err(where, f"kind {kind} is not allowed in a partner chart "
                       f"(allowed: {', '.join(sorted(ALLOWED_KINDS))}) — ask the NTUA team")
            continue
        if not name.startswith(prefix):
            err(where, f"name must start with '{prefix}' so it cannot collide with other releases")
        ns = meta.get("namespace")
        if ns not in (None, namespace):
            err(where, f"namespace {ns!r} is not allowed — leave it unset")

        if kind == "Service":
            stype = (doc.get("spec") or {}).get("type", "ClusterIP")
            if stype != "ClusterIP":
                err(where, f"Service type {stype} would expose it outside the cluster — use ClusterIP")

        if kind == "PersistentVolumeClaim":
            storage_mib += to_mib(((doc.get("spec") or {}).get("resources") or {})
                                  .get("requests", {}).get("storage", 0))
        if kind == "StatefulSet":
            replicas = (doc.get("spec") or {}).get("replicas", 1) or 1
            for tpl in (doc.get("spec") or {}).get("volumeClaimTemplates") or []:
                storage_mib += replicas * to_mib(((tpl.get("spec") or {}).get("resources") or {})
                                                 .get("requests", {}).get("storage", 0))

        spec = pod_spec(doc)
        if spec is None:
            continue
        for flag in ("hostNetwork", "hostPID", "hostIPC"):
            if spec.get(flag):
                err(where, f"{flag} is not allowed")
        for vol in spec.get("volumes") or []:
            if "hostPath" in vol:
                err(where, f"hostPath volume '{vol.get('name')}' is not allowed — use a PersistentVolumeClaim")
        replicas = (doc.get("spec") or {}).get("replicas", 1) if kind in ("Deployment", "StatefulSet") else 1
        for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
            cwhere = f"{where} container {c.get('name')}"
            image = str(c.get("image", ""))
            base = image.split("@")[0].split(":")[0].rsplit("/", 1)[-1]
            if base in PLATFORM_IMAGES:
                err(cwhere, f"image {image} is a platform service — use the platform's instead")
            limit = ((c.get("resources") or {}).get("limits") or {}).get("memory")
            if not limit:
                err(cwhere, "resources.limits.memory is required")
            elif c in (spec.get("containers") or []):
                memory_mib += (replicas or 1) * to_mib(limit)
            sc = c.get("securityContext") or {}
            if sc.get("privileged"):
                err(cwhere, "privileged containers are not allowed")
            if sc.get("allowPrivilegeEscalation") is True:
                err(cwhere, "allowPrivilegeEscalation: true is not allowed")
            for e in c.get("env") or []:
                if "value" not in e:
                    continue
                ename = e.get("name", "")
                if CREDENTIAL_LIKE.search(ename) and not LOCATION_NAME.search(ename):
                    err(cwhere, f"env {ename} has a literal value — read it from a Secret (valueFrom.secretKeyRef)")
                elif URL_WITH_PASSWORD.search(str(e.get("value", ""))):
                    err(cwhere, f"env {ename} contains a password inside a URL — read it from a Secret (valueFrom.secretKeyRef)")

    print(f"Checked {len(docs)} resources of {partner}'s chart: "
          f"memory limits {memory_mib:.0f} Mi, storage requests {storage_mib / 1024:.1f} Gi")
    if errors:
        for e in errors:
            print(f"::error::{e}")
        print(f"{len(errors)} rule violation(s) — see docs/partners-onboarding.md, 'Your own chart'.")
        sys.exit(1)
    print("All platform rules satisfied.")


if __name__ == "__main__":
    main()
