#!/usr/bin/env python3
"""tests/fake-oneshot-agent.py - a stand-in for a one-shot CLI (no MCP
calls): reads one prompt line from stdin, prints one JSON envelope, and
exits instead of waiting for the next message. Used by
tests/test-chat-persistent.lua to check the chat copes with an agent that
can't stay running.
"""
import json
import sys


def main():
    message = sys.stdin.readline()
    print(json.dumps({"type": "result", "result": "answered once: " + message.strip()[-20:], "session_id": "fake-oneshot-1"}))


if __name__ == "__main__":
    main()
