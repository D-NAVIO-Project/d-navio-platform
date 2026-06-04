#!/usr/bin/env bash

set -euo pipefail

echo "=== D-NAVIO Service Health Checks ==="
echo ""

check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "[OK] $1 is installed"
  else
    echo "[WARN] $1 is not installed"
  fi
}

check_url() {
  local name="$1"
  local url="$2"

  echo "Checking $name: $url"

  if curl -fsS --max-time 5 "$url" >/dev/null; then
    echo "[OK] $name is reachable"
  else
    echo "[FAIL] $name is not reachable"
  fi

  echo ""
}

echo "Checking local tooling..."
check_command docker
check_command kubectl
check_command curl

echo ""
echo "Checking Docker containers..."
if command -v docker >/dev/null 2>&1; then
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
else
  echo "[SKIP] Docker not available"
fi

echo ""
echo "Checking Kubernetes pods (all namespaces)..."
if command -v kubectl >/dev/null 2>&1; then
  kubectl get pods --all-namespaces || true
else
  echo "[SKIP] kubectl not available"
fi

echo ""
echo "Checking D-NAVIO platform pods (namespace: dnavio-dev)..."
if command -v kubectl >/dev/null 2>&1; then
  kubectl get pods,svc -n dnavio-dev 2>/dev/null || echo "[INFO] Namespace dnavio-dev not found or no access"
else
  echo "[SKIP] kubectl not available"
fi

echo ""
echo "Checking known service endpoints..."

# Replace these with the actual platform endpoints when finalized.
check_url "Keycloak" "http://localhost:8080/realms/master"
check_url "Kafka UI" "http://localhost:8081"
check_url "Platform API" "http://localhost:8000/health"

echo "Health check completed."
