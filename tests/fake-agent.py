#!/usr/bin/env python3
"""tests/fake-agent.py - a stand-in for Claude Code / the Copilot CLI that
tests/demo-smoke.lua configures as an agent action. It reads the context
bundle azure-vicli prepared (the AZVICLI_AGENT_* environment), checks the
working directory is the PR's worktree, and prints a markdown triage plus a
```json block of suggestions: a reply to the first active thread on
src/auth.py, a new comment on src/auth.py line 13, and a PR-level comment.

Usage: fake-agent.py [prompt...]   (the prompt is echoed back)
"""
import json
import os
import subprocess
import sys


def main():
    ctx = os.environ["AZVICLI_AGENT_CONTEXT"]
    with open(os.path.join(ctx, "pr.json"), encoding="utf-8") as f:
        pr = json.load(f)
    with open(os.environ["AZVICLI_AGENT_THREADS_FILE"], encoding="utf-8") as f:
        threads = json.load(f)
    with open(os.environ["AZVICLI_AGENT_DIFF_FILE"], encoding="utf-8") as f:
        diff = f.read()
    head = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()
    stdin = sys.stdin.read()

    active = [t for t in threads if t["status"] == "active" and t.get("file") == "src/auth.py"]
    print("# Triage of PR #{0}: {1}".format(pr["id"], pr["title"]))
    print()
    print("- prompt: " + " ".join(sys.argv[1:]))
    print("- stdin: " + stdin.strip())
    print("- worktree HEAD: " + head)
    print("- threads: {0}, diff touches auth.py: {1}".format(len(threads), "src/auth.py" in diff))
    print("- FAKE-AGENT-RAN")
    items = []
    if active:
        items.append({"thread_id": active[0]["id"], "verdict": "fix",
                      "note": "The caller can't tell a lockout from a bad password.",
                      "reply": "Good point - I'll return a reason code."})
    items.append({"file": "src/auth.py", "line": 13, "comment": "Log the lockout here too?"})
    items.append({"comment": "Please add a changelog entry."})
    print()
    print("```json")
    print(json.dumps({"summary": "1 to fix, 2 new comments", "items": items}, indent=2))
    print("```")


if __name__ == "__main__":
    main()
