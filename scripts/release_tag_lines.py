#!/usr/bin/env python3
"""Read commit SHAs from a GitHub tag ref or matching-refs payload."""

import json
import os
import re
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


def github_object(path):
    repo = os.environ["GITHUB_REPOSITORY"]
    raw = subprocess.check_output(["gh", "api", f"repos/{repo}/git/{path}"], text=True)
    return json.loads(raw)["object"]


def commit_sha(obj):
    while obj["type"] == "tag":
        obj = github_object(f"tags/{obj['sha']}")
    sha = obj["sha"].lower()
    if obj["type"] != "commit" or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit("Tag does not point at a commit.")
    return sha


def main():
    if len(sys.argv) == 2:
        print(commit_sha(github_object(f"ref/tags/{sys.argv[1]}")))
        return
    for ref in flatten(json.load(sys.stdin)):
        name = ref["ref"].removeprefix("refs/tags/")
        print(name, commit_sha(ref["object"]))


if __name__ == "__main__":
    main()
