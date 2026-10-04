#!/usr/bin/env python3
"""tests/fake-agent.py - a stand-in for Claude Code / the Copilot CLI that
tests/demo-smoke.lua configures as an agent action. It reads the context
bundle azure-vicli prepared (the AZVICLI_AGENT_* environment), checks the
working directory is the PR's worktree, and prints a markdown triage plus a
```json block of suggestions: a reply to the first active thread on
src/auth.py, a new comment on src/auth.py line 13, and a PR-level comment.

Usage: fake-agent.py [--json] [--resume ID] [prompt...]

--json wraps the output the way `claude -p --output-format json` does
({"result": ..., "session_id": ...}). --resume ID answers a follow-up the
way a resumed session would: it echoes the session id and the message
(stdin) and suggests one more PR comment. Without --resume, a stdin that
carries azure-vicli's replayed conversation is reported as such.
"""
import json
import os
import subprocess
import sys


def emit(text, as_json, session):
    if as_json:
        print(json.dumps({"type": "result", "result": text, "session_id": session}))
    else:
        print(text)


def block(obj):
    return "```json\n" + json.dumps(obj, indent=2) + "\n```"


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    resume = None
    if "--resume" in args:
        i = args.index("--resume")
        resume = args[i + 1]
        del args[i:i + 2]
    stdin = sys.stdin.read()

    if resume is not None:
        out = ["# Follow-up", "", "- resumed session: " + resume, "- you asked: " + stdin.strip(),
               "- FAKE-FOLLOWUP-RAN", "", block({"items": [{"comment": "From the follow-up."}]})]
        emit("\n".join(out), as_json, resume)
        return

    ctx = os.environ["AZVICLI_AGENT_CONTEXT"]
    with open(os.path.join(ctx, "pr.json"), encoding="utf-8") as f:
        pr = json.load(f)
    with open(os.environ["AZVICLI_AGENT_THREADS_FILE"], encoding="utf-8") as f:
        threads = json.load(f)
    with open(os.environ["AZVICLI_AGENT_DIFF_FILE"], encoding="utf-8") as f:
        diff = f.read()
    head = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True).stdout.strip()

    if "This is a follow-up." in stdin:
        out = ["# Replayed follow-up", "", "- saw my earlier answer: " + str("FAKE-AGENT-RAN" in stdin),
               "- question: " + stdin.split("Now the user asks:")[-1].split("\n")[1].strip(),
               "- FAKE-REPLAY-RAN"]
        emit("\n".join(out), as_json, "fake-session-1")
        return

    active = [t for t in threads if t["status"] == "active" and t.get("file") == "src/auth.py"]
    out = ["# Triage of PR #{0}: {1}".format(pr["id"], pr["title"]), "",
           "- prompt: " + " ".join(args),
           "- stdin: " + stdin.strip(),
           "- worktree HEAD: " + head,
           "- threads: {0}, diff touches auth.py: {1}".format(len(threads), "src/auth.py" in diff),
           "- FAKE-AGENT-RAN"]
    items = []
    if active:
        items.append({"thread_id": active[0]["id"], "verdict": "fix",
                      "note": "The caller can't tell a lockout from a bad password.",
                      "reply": "Good point - I'll return a reason code."})
    items.append({"file": "src/auth.py", "line": 13, "comment": "Log the lockout here too?"})
    items.append({"comment": "Please add a changelog entry."})
    out += ["", block({"summary": "1 to fix, 2 new comments", "items": items})]
    emit("\n".join(out), as_json, "fake-session-1")


if __name__ == "__main__":
    main()
