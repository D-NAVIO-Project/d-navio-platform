#!/usr/bin/env python3
"""Render the D-NAVIO cluster overview.

cluster-overview.sh collects the raw data (kubectl / helm JSON, cgroup memory
files, Kafka probe logs) into a directory; this program turns it into the
report and decides the exit status. Run cluster-overview.sh, not this file.

Statuses and what they mean for OVERALL and the exit status:
  OK, FLOWING, RUNNING      fine
  NO DATA, BACKLOG, SKIPPED  informational
  WARN, STALLED, UNKNOWN     OVERALL: WARNING  (exit 0; 1 with --strict)
  FAIL                       OVERALL: FAILED   (exit 1)
"""
import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

NOW = datetime.now(timezone.utc)
LEVEL = {"OK": 0, "FLOWING": 0, "RUNNING": 0, "NO DATA": 0, "BACKLOG": 0, "SKIPPED": 0,
         "WARN": 1, "STALLED": 1, "UNKNOWN": 1, "FAIL": 2}
COLOURS = {"OK": "32", "FLOWING": "32", "RUNNING": "32", "NO DATA": "36", "BACKLOG": "36",
           "SKIPPED": "2", "WARN": "33", "STALLED": "33", "UNKNOWN": "33", "FAIL": "1;31",
           "WARNING": "33", "FAILED": "1;31", "BOLD": "1"}
RULE = "─" * 64


# --- small helpers -------------------------------------------------------------

def ts(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def age(t):
    if t is None:
        return "?"
    s = int((NOW - t).total_seconds())
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


UNITS = {"": 1, "k": 1e3, "K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12,
         "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40}


def to_bytes(q):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|k|K|M|G|T)?", str(q or "").strip())
    return float(m.group(1)) * UNITS[m.group(2) or ""] if m else 0.0


def gib(n):
    return f"{n / 2**30:.1f}Gi"


def mib(n):
    return f"{n / 2**20:.0f}Mi"


def window_label(minutes):
    if minutes < 120:
        return f"{minutes} min"
    if minutes < 2880:
        return f"{minutes // 60} h"
    return f"{minutes // 1440} d"


def owner_name(pod):
    """Workload-style name of a pod (without the ReplicaSet / pod hashes)."""
    name = pod["metadata"]["name"]
    refs = pod["metadata"].get("ownerReferences") or []
    if refs and refs[0].get("kind") == "ReplicaSet":
        return name.rsplit("-", 2)[0]
    if refs and refs[0].get("kind") == "Job":
        return refs[0].get("name", name)
    return name


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


# --- report ------------------------------------------------------------------------

class Report:
    def __init__(self, colour, details):
        self.colour = colour
        self.details = details
        self.findings = []   # (status, env, text): what OVERALL lists
        self.notes = []      # (env, text): informational, shown with --details

    def paint(self, text, status):
        code = COLOURS.get(status)
        return f"\033[{code}m{text}\033[0m" if self.colour and code else text

    def header(self, title):
        print("\n" + self.paint(title, "BOLD"))

    def row(self, label, status, text="", env=None, finding=None):
        """One line of the overview; WARN/FAIL/UNKNOWN rows also go into OVERALL."""
        print(f"  {label:<20} {self.paint(f'{status:<9}', status)} {text}".rstrip())
        if LEVEL.get(status, 0) and env is not None:
            self.findings.append((status, env, finding or f"{label}: {text}"))

    def detail(self, text):
        if self.details:
            print(f"      {text}")


def cluster_section(r, data, resources_by_ns):
    r.header("CLUSTER")
    if data is None:
        r.row("Node readiness", "FAIL", "Kubernetes API request failed", env="cluster")
        return
    items = data.get("items", [])
    nodes = [x for x in items if x.get("kind") == "Node"]
    ready, pressure = 0, []
    for n in nodes:
        conds = {c.get("type"): c.get("status") for c in n.get("status", {}).get("conditions", [])}
        ready += conds.get("Ready") == "True"
        pressure += [f"{n['metadata']['name']} {t}" for t in ("MemoryPressure", "DiskPressure", "PIDPressure")
                     if conds.get(t) == "True"]
    r.row("Node readiness", "OK" if nodes and ready == len(nodes) else "FAIL",
          f"{ready}/{len(nodes)} Ready", env="cluster")
    if pressure:
        r.row("Node pressure", "WARN", ", ".join(pressure) + " (the kubelet evicts pods)", env="cluster")

    deps = [d for res in resources_by_ns.values() if res for d in res.get("items", [])
            if d.get("kind") == "Deployment"]
    ready_deps = sum(deployment_ready(d) for d in deps)
    r.row("Deployments", "OK" if ready_deps == len(deps) else "FAIL",
          f"{ready_deps}/{len(deps)} Ready (checked namespaces)", env="cluster")

    alloc = sum(to_bytes(n.get("status", {}).get("allocatable", {}).get("memory")) for n in nodes)
    req = lim = 0.0
    for p in items:
        if p.get("kind") != "Pod" or p.get("status", {}).get("phase") not in ("Pending", "Running"):
            continue
        for c in p.get("spec", {}).get("containers", []):
            res = c.get("resources") or {}
            req += to_bytes((res.get("requests") or {}).get("memory"))
            lim += to_bytes((res.get("limits") or {}).get("memory"))
    if alloc:
        status = "WARN" if req / alloc >= 0.9 else "OK"
        r.row("Memory budget", status,
              f"{req / alloc:.0%} requested, {lim / alloc:.0%} in limits, of {gib(alloc)}", env="cluster",
              finding=f"pod memory requests at {req / alloc:.0%} of the node: new pods may not schedule")
        if lim > alloc:
            r.notes.append(("cluster", f"memory limits ({gib(lim)}) exceed the node ({gib(alloc)}): "
                                       "under load the kubelet evicts pods"))


def deployment_ready(d):
    want = d.get("spec", {}).get("replicas", 1)
    s = d.get("status", {})
    return (s.get("readyReplicas", 0) >= want and s.get("updatedReplicas", 0) >= want
            and s.get("observedGeneration", 0) >= d["metadata"].get("generation", 1))


def kubernetes_row(r, env, ns, res, releases, recent_hours):
    """One line summarising deployments, pods, jobs, PVCs, restarts, failed pods, Helm."""
    recent = lambda t: t is not None and (NOW - t).total_seconds() < recent_hours * 3600
    items = [x for x in res.get("items", [])
             if "dnavio.ops/cluster-overview" not in (x.get("metadata", {}).get("labels") or {})]
    kind = lambda k: [x for x in items if x.get("kind") == k]
    fails, warns, lines = [], [], []

    deps = kind("Deployment")
    bad_deps = [d for d in deps if not deployment_ready(d)]
    if bad_deps:
        fails.append(f"{len(bad_deps)}/{len(deps)} deployments not ready")
    for d in bad_deps:
        s = d.get("status", {})
        lines.append(f"deployment/{d['metadata']['name']}: {s.get('readyReplicas', 0)}/"
                     f"{d.get('spec', {}).get('replicas', 1)} ready")
    if not any(d["metadata"]["name"] == "kafka" for d in deps):
        fails.append("no kafka Deployment")

    pods = kind("Pod")
    active = [p for p in pods if not p["metadata"].get("deletionTimestamp")
              and p.get("status", {}).get("phase") in ("Pending", "Running")]

    def ready(p):
        cs = p.get("status", {}).get("containerStatuses") or []
        return p["status"].get("phase") == "Running" and bool(cs) and all(c.get("ready") for c in cs)

    def why(p):
        st = p.get("status", {})
        for c in (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or []):
            state = c.get("state") or {}
            if "waiting" in state:
                w = state["waiting"]
                msg = (w.get("message") or "")[:120]
                return f"{c.get('name')}: {w.get('reason') or 'waiting'}" + (f" ({msg})" if msg else "")
            if "running" in state and not c.get("ready", True):
                return f"{c.get('name')}: running, not ready"
        for cond in st.get("conditions") or []:
            if cond.get("status") == "False" and cond.get("reason"):
                return f"{cond.get('reason')}: {(cond.get('message') or '')[:120]}"
        return st.get("phase", "?")

    not_ready = [p for p in active if not ready(p)]
    if not_ready:
        fails.append(f"{len(not_ready)}/{len(active)} pods not ready")
    lines += [f"pod/{p['metadata']['name']}: {why(p)}" for p in not_ready]

    restarts = []
    for p in active:
        for c in p.get("status", {}).get("containerStatuses") or []:
            if c.get("restartCount", 0):
                t = (c.get("lastState") or {}).get("terminated") or {}
                restarts.append((owner_name(p), c.get("name"), c["restartCount"],
                                 t.get("reason") or "unknown", ts(t.get("finishedAt"))))
    fresh = [x for x in restarts if recent(x[4])]
    if fresh:
        warns.append(f"{len(fresh)} container restart(s) in the last {recent_hours}h ("
                     + ", ".join(f"{x[0]} {x[3]}" for x in fresh) + ")")
    old_oom = [x for x in restarts if x[3] == "OOMKilled" and not recent(x[4])]
    if old_oom:
        r.notes.append((env, "earlier OOM kills: " + ", ".join(f"{x[0]} {age(x[4])} ago" for x in old_oom)))
    lines += [f"restarts {x[0]}/{x[1]}: {x[2]}x, last {x[3]} {age(x[4])} ago" for x in restarts]

    failed = [p for p in pods if p.get("status", {}).get("phase") in ("Failed", "Unknown")]
    if failed:
        def ended(p):
            times = [ts(c.get("lastTransitionTime")) for c in p.get("status", {}).get("conditions") or []]
            times = [t for t in times if t]
            return max(times) if times else ts(p["metadata"].get("creationTimestamp"))
        groups = {}
        for p in failed:
            groups.setdefault(p["status"].get("reason") or p["status"].get("phase"), []).append(p)
        newest = max((t for t in map(ended, failed) if t), default=None)
        summary = ", ".join(f"{len(v)} {k}" for k, v in sorted(groups.items()))
        if recent(newest):
            warns.append(f"failed pods: {summary} (newest {age(newest)} ago)")
        else:
            r.notes.append((env, f"old failed pods: {summary} (newest {age(newest)} ago); remove with "
                                 f"kubectl delete pod -n {ns} --field-selector=status.phase=Failed"))
        for reason, group in sorted(groups.items()):
            lines.append(f"failed pods {reason}: " + ", ".join(sorted({owner_name(p) for p in group})))

    jobs = kind("Job")
    failed_jobs = [j for j in jobs if any(c.get("type") == "Failed" and c.get("status") == "True"
                                          for c in j.get("status", {}).get("conditions") or [])]
    if failed_jobs:
        fails.append(f"{len(failed_jobs)} failed job(s): " + ", ".join(j["metadata"]["name"] for j in failed_jobs))

    pvcs = kind("PersistentVolumeClaim")
    unbound = [x for x in pvcs if x.get("status", {}).get("phase") != "Bound"]
    if unbound:
        fails.append(f"{len(unbound)} PVC(s) not Bound: " + ", ".join(x["metadata"]["name"] for x in unbound))

    if releases is None:
        r.notes.append((env, "Helm releases not checked (helm missing or not permitted)"))
        rel_text = "Helm not checked"
    else:
        bad_rel = [x for x in releases if x.get("status") != "deployed"]
        if not releases:
            fails.append("no Helm release")
        for x in bad_rel:
            fails.append(f"Helm release {x.get('name')} is {x.get('status')}")
        lines += [f"helm {x.get('name')}: {x.get('status')} (rev {x.get('revision')}, {x.get('chart')})"
                  for x in releases]
        rel_text = f"{len(releases) - len(bad_rel)}/{len(releases)} releases deployed"

    if fails:
        r.row("Kubernetes", "FAIL", "; ".join(fails), env=env, finding="; ".join(fails))
        for w in warns:
            r.findings.append(("WARN", env, w))
    elif warns:
        r.row("Kubernetes", "WARN", "; ".join(warns), env=env, finding="; ".join(warns))
    else:
        r.row("Kubernetes", "OK", f"{len(deps)} deployments, {len(active)} pods, {len(pvcs)} PVCs ready; {rel_text}")
    for line in lines:
        r.detail(line)


def memory_row(r, env, label, text, warn_pct):
    vals = dict(line.split()[:2] for line in (text or "").splitlines() if len(line.split()) >= 2)
    if "anon" not in vals or "max_bytes" not in vals:
        r.row(label, "UNKNOWN", "cgroup memory not readable (pod down, or no exec permission)", env=env)
        return
    anon, limit, kills = int(vals["anon"]), vals["max_bytes"], int(vals.get("oom_kill", 0))
    if limit == "max":
        r.row(label, "OK", f"{mib(anon)}, no limit")
        return
    limit = int(limit)
    pct = anon * 100 / limit
    text = f"{pct:.0f}% of {mib(limit)}"
    problems = []
    if pct >= warn_pct:
        text += f", {mib(limit - anon)} left"
        problems.append(f"{label} at {pct:.0f}% of its {mib(limit)} limit ({mib(limit - anon)} left): "
                        "any extra process in the container risks an OOM kill")
    if kills:
        text += f", {kills} OOM kill(s) since start"
        problems.append(f"{label}: {kills} OOM kill(s) inside the container since it started")
    r.row(label, "WARN" if problems else "OK", text, env=env, finding="; ".join(problems))


def parse_probe(text):
    section, end, since, errors = None, {}, {}, []
    for line in (text or "").splitlines():
        line = line.strip()
        if line.startswith("@@ "):
            section = line[3:]
            continue
        m = re.fullmatch(r"(\S+):(\d+):(-?\d*)", line)
        if m and section in ("end", "since"):
            target = end if section == "end" else since
            target.setdefault(m.group(1), {})[int(m.group(2))] = int(m.group(3)) if m.group(3) else -1
        elif section == "error" and line:
            errors.append(line)
    return end, since, errors


def kafka_rows(r, env, d, args, expected):
    tlabel = f"Telemetry ({window_label(args.window)})"
    if args.fast:
        r.row("Kafka connectivity", "SKIPPED", "--fast: broker container state only, no client test")
        return
    state = (read_text(os.path.join(d, "probe.state")) or "").strip()
    log = read_text(os.path.join(d, "probe.log"))
    at = read_text(os.path.join(d, "probe.at"))
    checked = ""
    if args.watch and at and at.strip().isdigit():
        checked = f" · checked {int(time.time()) - int(at)}s ago"
    end, since, errors = parse_probe(log)
    if not state.startswith("ok") or not end:
        reason = state.split("\t", 1)[1] if "\t" in state else "no probe result"
        if errors:
            reason += ": " + " | ".join(errors[-2:])
        reason = reason[:220]
        r.row("Kafka connectivity", "UNKNOWN", reason, env=env,
              finding=f"Kafka could not be verified: {reason}")
        r.row("Kafka topics", "UNKNOWN", "needs the Kafka check")
        r.row(tlabel, "UNKNOWN", "needs the Kafka check")
        return
    r.row("Kafka connectivity", "OK", f"Keycloak token accepted, offsets read on kafka:9092{checked}")

    if expected:
        missing = [t for t in expected if t not in end]
        other = sorted(set(end) - set(expected))
        text = f"{len(expected) - len(missing)}/{len(expected)} present"
        if missing:
            text += ", missing: " + ", ".join(missing)
        r.row("Kafka topics", "FAIL" if missing else "OK", text, env=env)
        if other:
            r.detail("other topics: " + ", ".join(other))
    else:
        r.row("Kafka topics", "OK", f"{len(end)} topics (expected list unavailable: helm values not readable)")

    counts, totals = {}, {}
    for t in args.telemetry:
        if t not in end:
            counts[t] = None
            continue
        totals[t] = sum(end[t].values())
        counts[t] = sum(max(eo - since.get(t, {}).get(p, -1), 0)
                        for p, eo in end[t].items() if since.get(t, {}).get(p, -1) >= 0)
    raw, norm = (counts.get(t) for t in args.telemetry[:2])
    shown = " · ".join(f"{t.rsplit('.', 1)[-1]} +{counts[t]:,}" for t in args.telemetry if counts[t] is not None)
    if raw is None or norm is None:
        r.row(tlabel, "FAIL", "telemetry topic missing", env=env)
    elif raw and norm:
        r.row(tlabel, "FLOWING", shown)
    elif raw:
        r.row(tlabel, "STALLED", f"{shown}: received but not normalised, check T4.2 stream-processor", env=env,
              finding="telemetry arrives on raw but is not normalised: check T4.2 stream-processor")
    elif norm:
        r.row(tlabel, "BACKLOG", f"{shown}: only normalised output (T4.2 working through a backlog?)")
    else:
        r.row(tlabel, "NO DATA", "nothing arrived; the platform can still be healthy")
    for t, n in totals.items():
        r.detail(f"{t}: {n:,} messages written in total (end offset)")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data", required=True)
    ap.add_argument("--context", default="")
    ap.add_argument("--namespaces", nargs="+", required=True)
    ap.add_argument("--telemetry", nargs="+", required=True)
    ap.add_argument("--window", type=int, default=15)
    ap.add_argument("--recent-hours", type=int, default=24)
    ap.add_argument("--mem-warn", type=float, default=90)
    ap.add_argument("--fast", action="store_true")
    ap.add_argument("--details", action="store_true")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--colour", action="store_true")
    ap.add_argument("--watch", type=int, default=0)
    args = ap.parse_args()

    r = Report(args.colour, args.details)
    print("D-NAVIO CLUSTER OVERVIEW")
    print(f"{NOW:%Y-%m-%d %H:%M:%S} UTC · context {args.context or '?'}"
          + (" · --fast (no Kafka checks)" if args.fast else ""))
    print(RULE)

    resources = {ns: read_json(os.path.join(args.data, ns, "resources.json")) for ns in args.namespaces}
    cluster_section(r, read_json(os.path.join(args.data, "cluster.json")), resources)

    for ns in args.namespaces:
        d = os.path.join(args.data, ns)
        env = ns[len("dnavio-"):] if ns.startswith("dnavio-") else ns
        r.header(f"{env.upper()} ENVIRONMENT ({ns})")
        res = resources[ns]
        if res is None:
            r.row("Kubernetes", "FAIL", "namespace missing, forbidden, or API unreachable", env=env)
            continue
        releases = read_json(os.path.join(d, "helm.json"))
        values = read_json(os.path.join(d, "values.json")) or {}
        expected = [t.get("name") for t in values.get("kafka", {}).get("topics", []) if t.get("name")]
        kubernetes_row(r, env, ns, res, releases, args.recent_hours)
        kafka_rows(r, env, d, args, expected)
        memory_row(r, env, "Kafka memory", read_text(os.path.join(d, "kafka-memory.txt")), args.mem_warn)
        memory_row(r, env, "Keycloak memory", read_text(os.path.join(d, "keycloak-memory.txt")), args.mem_warn)

    print("\n" + RULE)
    worst = max((LEVEL[s] for s, _, _ in r.findings), default=0)
    overall = {0: "OK", 1: "WARNING", 2: "FAILED"}[worst]
    print(f"OVERALL: {r.paint(overall, overall)}")
    if not r.findings:
        print("  all checks passed")
    width = max((len(e) for _, e, _ in r.findings), default=0)
    for status, env, text in sorted(r.findings, key=lambda f: -LEVEL[f[0]]):
        print(f"  {r.paint(f'{status:<8}', status)} {env:<{width}}  {text}")
    if r.notes:
        if args.details:
            print("\nNotes")
            for env, text in r.notes:
                print(f"  {env}: {text}")
        else:
            print(f"  ({len(r.notes)} note(s), and the per-item list: run with --details)")
    elif r.findings and not args.details:
        print("  (per-item list: run with --details)")

    if worst == 2 or (worst == 1 and args.strict):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
