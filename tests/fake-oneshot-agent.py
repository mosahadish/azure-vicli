#!/usr/bin/env python3
"""tests/fake-oneshot-agent.py - a minimal stand-in for a one-shot `-p`
CLI (no persistent/stream protocol, no MCP calls): reads the whole prompt
from stdin, prints one JSON envelope, and exits. Used by
tests/test-chat-persistent.lua to check the ordinary (non-persistent)
send/followup/resume path still works exactly as before chat/init.lua's
`send` was refactored to share its turn-finishing code with the
persistent path.

Usage: fake-oneshot-agent.py [--resume ID]
"""
import json
import sys


def main():
    args = sys.argv[1:]
    resume = args[args.index("--resume") + 1] if "--resume" in args else None
    message = sys.stdin.read()
    asked = message.split("## Message\n", 1)[-1].strip()
    session = resume or "fake-oneshot-1"
    text = "resumed: {0}, asked: {1}".format(bool(resume), asked)
    print(json.dumps({"type": "result", "result": text, "session_id": session}))


if __name__ == "__main__":
    main()
