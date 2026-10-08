#!/usr/bin/env python3
"""tests/fake-persistent-agent.py - a stand-in for a CLI that supports
Claude Code's `-p --input-format stream-json --output-format stream-json`:
one process, read a JSON "user message" line from stdin, answer with a
stream of JSON events ending in a "result" line, then loop back to read
the next line - until stdin closes. Used by tests/test-chat-persistent.lua
to check chat/init.lua's agent.persistent path actually reuses the process
across messages instead of starting a new one each time.

Each answer reports its own pid and an increasing turn counter, so the
test can tell a reused process (same pid, turn 1 then turn 2) from a
respawned one (same pid is impossible to rule out that way alone, so the
test also checks only one process ever starts: see its --marker-file).
"""
import json
import os
import sys


def main():
    args = sys.argv[1:]

    def opt(name):
        if name in args:
            return args[args.index(name) + 1]
        return None

    marker = opt("--marker-file")
    if marker:
        with open(marker, "a", encoding="utf-8") as f:
            f.write(str(os.getpid()) + "\n")

    session = "fake-persistent-1"
    turn = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        turn += 1
        req = json.loads(line)
        text = req.get("message", {}).get("content", [{}])[0].get("text", "")
        asked = text.split("## Message\n", 1)[-1].strip()
        answer = "turn {0}, pid {1}: {2}".format(turn, os.getpid(), asked)

        def emit(ev):
            sys.stdout.write(json.dumps(ev) + "\n")
            sys.stdout.flush()

        if turn == 1:
            emit({"type": "system", "subtype": "init", "session_id": session})
        emit({"type": "assistant", "message": {"content": [{"type": "text", "text": answer}]}})
        emit({"type": "result", "subtype": "success", "result": answer, "session_id": session})


if __name__ == "__main__":
    main()
