"""Fail closed unless the exact source passed independent full validation."""

import json
import re
import sys


def verified_run(payload, commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected an exact source commit SHA")
    if not isinstance(payload, dict) or not isinstance(payload.get("workflow_runs"), list):
        raise ValueError("Invalid Actions workflow response")
    runs = [
        run for run in payload["workflow_runs"]
        if run.get("head_sha") == commit
        and run.get("head_branch") == "feat/global-translation-floating-window"
        and run.get("path") == ".github/workflows/translation-validation.yml"
    ]
    if not runs:
        raise ValueError("Exact source has no independent full translation validation")
    # Never substitute an older successful run for a newer failure or pending run.
    latest = max(runs, key=lambda run: int(run["id"]))
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("Latest independent full translation validation has not passed")
    return latest["id"]


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: verify_translation_release_gate.py COMMIT RESPONSE_JSON")
    with open(sys.argv[2], encoding="utf-8") as source:
        run_id = verified_run(json.load(source), sys.argv[1])
    print(f"Verified independent full translation validation run {run_id} for {sys.argv[1]}")
