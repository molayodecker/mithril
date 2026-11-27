#!/usr/bin/env python3
"""Print "<tag> <commit-sha>" lines from a GitHub matching-refs payload."""

import json
import os
import subprocess
import sys


def flatten(payload):
    if isinstance(payload, dict):
        return [payload]
    if not isinstance(payload, list) or not payload:
        return []
    if isinstance(payload[0], list):
        return [item for page in payload for item in page]
    return payload


def commit_sha(obj):
    sha = obj["sha"]
    kind = obj.get("type")
    if kind == "commit":
        return sha
    if kind != "tag":
        raise SystemExit(f"unsupported git object {kind}")
    repo = os.environ["GITHUB_REPOSITORY"]
    raw = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/git/tags/{sha}"],
        text=True,
    )
    peeled = json.loads(raw)["object"]
    if peeled.get("type") != "commit":
        raise SystemExit(f"annotated tag {sha} does not point at a commit")
    return peeled["sha"]


def main():
    for ref in flatten(json.load(sys.stdin)):
        name = ref["ref"].removeprefix("refs/tags/")
        print(name, commit_sha(ref["object"]))


if __name__ == "__main__":
    main()
