# Service Health / Status Checks

## Purpose

This guide describes how to perform basic health and status checks for the
D-NAVIO platform services.

The purpose is to provide a repeatable way for developers and technical partners
to verify whether the core services are running and reachable.

## Scope

This guide covers:

- Local tooling checks
- Docker container status
- Kubernetes pod status
- Basic endpoint reachability checks
- Initial service troubleshooting steps

This guide does not define final production monitoring, alerting, or
partner-specific operational procedures.

## Script Location

The health check script is located at:

```bash
scripts/check-services.sh
```

## Usage

From the repository root:

```bash
chmod +x scripts/check-services.sh
./scripts/check-services.sh
```

## Checks Performed

The script currently checks:

**Required local tools:**
- Docker
- kubectl
- curl

**Running Docker containers:**
```bash
docker ps
```

**Kubernetes pod status (all namespaces):**
```bash
kubectl get pods --all-namespaces
```

**D-NAVIO platform pods (namespace: dnavio-dev):**
```bash
kubectl get pods,svc -n dnavio-dev
```

**Reachability of known service endpoints:**
- Keycloak
- Kafka UI
- Platform API health endpoint

## Expected Output

A healthy local setup should show:

```text
[OK] docker is installed
[OK] kubectl is installed
[OK] curl is installed
[OK] Keycloak is reachable
[OK] Platform API is reachable
```

Some services may return `[FAIL]` if they are not currently deployed, not
exposed locally, or running under different ports.

## Current Assumptions

The current script uses placeholder local endpoints:

| Service      | Endpoint                             |
|--------------|--------------------------------------|
| Keycloak     | `http://localhost:8080/realms/master` |
| Kafka UI     | `http://localhost:8081`              |
| Platform API | `http://localhost:8000/health`       |

These endpoints should be updated once the final local, VM, or Kubernetes
deployment configuration is confirmed.

For Kubernetes access, use `kubectl port-forward` before running the script:

```bash
kubectl port-forward svc/keycloak 8080:8080 -n dnavio-dev
```

## Troubleshooting

### Docker containers are not visible

```bash
docker compose ps
docker ps -a
```

### Kubernetes pods are not visible

Check that the correct context is selected:

```bash
kubectl config current-context
kubectl get namespaces
```

### A service is not reachable

Check whether the service is running and exposed:

```bash
kubectl get svc --all-namespaces
kubectl get ingress --all-namespaces
```

For local Kubernetes access, port-forwarding may be required:

```bash
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n <namespace>
```

## Next Improvements

Planned improvements:

- Replace placeholder endpoints with confirmed D-NAVIO service endpoints
- Add namespace-specific Kubernetes checks
- Add Keycloak realm/client verification
- Add Kafka broker/topic status checks
- Add structured JSON output for CI/CD usage
- Add CI validation for documentation and manifests
