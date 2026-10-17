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

Issue #65: stdin is read on a thread, so a control_request can arrive
mid-turn. An "interrupt" is answered like Claude Code does: a
control_response "success", then the turn ends with a `result` of
"error_during_execution" that has no `result` text. A message containing
"ignore interrupts" makes it read the interrupt and carry on regardless.
Every control_request is logged to --control-log, one subtype per line.
"""
import json
import os
import queue
import sys
import threading
import time


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
    control_log = opt("--control-log")

    def emit(ev):
        sys.stdout.write(json.dumps(ev) + "\n")
        sys.stdout.flush()

    lines = queue.Queue()

    def read():
        for line in sys.stdin:
            line = line.strip()
            if line:
                lines.put(json.loads(line))
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()

    def control(req):
        """Answers a control_request; True when it's an interrupt."""
        sub = req.get("request", {}).get("subtype")
        if control_log:
            with open(control_log, "a", encoding="utf-8") as f:
                f.write(str(sub) + "\n")
        emit({"type": "control_response", "response": {"subtype": "success",
              "request_id": req.get("request_id"), "response": {}}})
        return sub == "interrupt"

    session = "fake-persistent-1"
    turn = 0
    held = []  # user messages that arrived mid-turn
    while True:
        req = held.pop(0) if held else lines.get()
        if req is None:
            break
        if req.get("type") == "control_request":
            control(req)  # between turns: nothing to stop
            continue
        turn += 1
        text = req.get("message", {}).get("content", [{}])[0].get("text", "")
        asked = text.split("## Message\n", 1)[-1].strip()
        answer = "turn {0}, pid {1}: {2}".format(turn, os.getpid(), asked)
        if os.environ.get("AZVICLI_CHAT_AGENT"):
            answer += " [agent {0}]".format(os.environ["AZVICLI_CHAT_AGENT"])
        deaf = "ignore interrupts" in asked

        def wait(seconds):
            """Sleeps, reading stdin meanwhile; True if the turn was interrupted."""
            until = time.time() + seconds
            while True:
                left = until - time.time()
                if left <= 0:
                    return False
                try:
                    got = lines.get(timeout=left)
                except queue.Empty:
                    return False
                if got is None:
                    lines.put(None)
                    time.sleep(left)
                    return False
                if got.get("type") != "control_request":
                    held.append(got)
                elif control(got) and not deaf:
                    emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
                          "session_id": session, "total_cost_usd": round(0.01 * turn, 4),
                          "usage": {"input_tokens": 10, "output_tokens": 1}})
                    return True

        if "slowly" in asked:
            time.sleep(1)

        if turn == 1:
            emit({"type": "system", "subtype": "init", "session_id": session})
        # Issue #27's timeouts: "go quiet" starts and then says nothing for
        # 6s; "stream steadily" sends a chunk every 0.3s for 3s (9s when
        # it ignores interrupts, to outlast the cap and the grace period).
        if "go quiet" in asked:
            emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "Thinking..."}]}})
            if wait(6):
                continue
        if "stream steadily" in asked:
            stopped = False
            for n in range(30 if deaf else 10):
                emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "chunk {0}\n".format(n)}]}})
                if wait(0.3):
                    stopped = True
                    break
            if stopped:
                continue
        emit({"type": "assistant", "message": {"content": [{"type": "text", "text": answer}]}})
        # Like Claude Code: the process's cost so far, and this turn's tokens.
        emit({"type": "result", "subtype": "success", "result": answer, "session_id": session,
              "total_cost_usd": round(0.01 * turn, 4), "usage": {"input_tokens": 10, "output_tokens": 5}})


if __name__ == "__main__":
    main()
