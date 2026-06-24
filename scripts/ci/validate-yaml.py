#!/usr/bin/env python3
"""Validate YAML files in the D-NAVIO repository.

Walks each target path, parses every YAML document with yaml.safe_load_all,
collects failures, and exits 1 if any file fails to parse.

Run from the repository root:
    python3 scripts/ci/validate-yaml.py
"""
from pathlib import Path
import sys
import yaml

SEARCH_TARGETS = [
    Path(".github"),
    Path("helm"),
    Path("infra"),
]

# Helm template files use Go template syntax — not valid YAML until rendered.
# They are validated by 'helm lint' and 'kubeconform' in CI instead.
SKIP_DIRS = {"templates"}

errors: list[tuple[Path, Exception]] = []


def validate_yaml_file(path: Path) -> None:
    try:
        with path.open("r", encoding="utf-8") as f:
            list(yaml.safe_load_all(f))
        print(f"[OK] {path}")
    except Exception as exc:
        errors.append((path, exc))
        print(f"[FAIL] {path}: {exc}")


for target in SEARCH_TARGETS:
    if target.is_file():
        validate_yaml_file(target)
    elif target.is_dir():
        yaml_paths = sorted(
            p for p in list(target.rglob("*.yml")) + list(target.rglob("*.yaml"))
            if not any(part in SKIP_DIRS for part in p.parts)
        )
        for path in yaml_paths:
            validate_yaml_file(path)

if errors:
    print("")
    print("YAML validation failed:")
    for path, exc in errors:
        print(f"- {path}: {exc}")
    sys.exit(1)

print("")
print("YAML validation completed successfully.")
