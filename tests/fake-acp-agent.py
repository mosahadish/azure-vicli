#!/usr/bin/env python3
"""tests/fake-acp-agent.py - a stand-in for `copilot --acp`: Agent Client
Protocol (JSON-RPC 2.0, one message per line) on stdin/stdout. Like the
real one (1.0.92), it advertises only http/sse MCP servers and rejects a
stdio one. At session/new it calls the http server it was given
(tools/list, then current_view), the way Copilot would, and every
session/prompt answer reports that, its pid and a turn counter - so
tests/test-chat-acp.lua can tell the session stayed warm and that
azure-vicli's tools reached it.

Usage: fake-acp-agent.py [--marker-file PATH]
"""
import json
import os
import sys
import urllib.request


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def mcp_call(server, mid, method, params=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    for h in server.get("headers") or []:
        headers[h["name"]] = h["value"]
    body = json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(server["url"], data=body, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def main():
    args = sys.argv[1:]
    if "--marker-file" in args:
        with open(args[args.index("--marker-file") + 1], "a", encoding="utf-8") as f:
            f.write(str(os.getpid()) + "\n")
    tools_seen = "no azure-vicli tools"
    turn = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {
                "mcpCapabilities": {"http": True, "sse": True}}}})
        elif method == "session/new":
            for server in params.get("mcpServers") or []:
                if server.get("type") != "http":
                    sys.stderr.write("Rejecting non-http/sse MCP server {0!r} from client\n".format(server.get("name")))
                    continue
                try:
                    mcp_call(server, 1, "initialize", {"protocolVersion": "2025-06-18"})
                    names = [t["name"] for t in mcp_call(server, 2, "tools/list")["result"]["tools"]]
                    view = mcp_call(server, 3, "tools/call", {"name": "current_view", "arguments": {}})
                    tools_seen = "tools: {0} tool(s), current_view ok: {1}".format(
                        len(names), not view["result"].get("isError"))
                except Exception as ex:  # noqa: BLE001 - reported in the answer
                    tools_seen = "http MCP failed: {0}".format(ex)
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "fake-acp-1"}})
        elif method == "session/prompt":
            turn += 1
            text = "turn {0}, pid {1}, {2}".format(turn, os.getpid(), tools_seen)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                  "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})


if __name__ == "__main__":
    main()
