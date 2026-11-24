#!/usr/bin/env python3
"""Render apps/orders-api/rollout.yaml for a given release.

The image is the same binary for every version on purpose: what changes is the
tag (so the ReplicaSet hash changes and Argo Rollouts sees a new revision) and
the APP_VERSION/FAIL_RATE env vars (so the canary can be made to misbehave
deterministically, without rebuilding anything).

Usage: render-version.py <tag> <app_version> <fail_rate> [path-to-rollout.yaml]
Prints the rendered manifest on stdout.
"""
import re
import sys

tag, app_version, fail_rate = sys.argv[1], sys.argv[2], sys.argv[3]
path = sys.argv[4] if len(sys.argv) > 4 else "apps/orders-api/rollout.yaml"

with open(path, encoding="utf-8") as fh:
    text = fh.read()


def set_env(doc: str, name: str, value: str) -> str:
    pattern = rf"(?m)^(\s*- name: {name}\n\s*value: )\"[^\"]*\"$"
    new_doc, count = re.subn(pattern, rf'\g<1>"{value}"', doc)
    if count != 1:
        raise SystemExit(f"expected exactly one '{name}' env var, found {count}")
    return new_doc


text = re.sub(r"(?m)^(\s*image: ghcr\.io/[^:]+):\S+$", rf"\g<1>:{tag}", text)
text = set_env(text, "APP_VERSION", app_version)
text = set_env(text, "FAIL_RATE", fail_rate)

sys.stdout.write(text)
