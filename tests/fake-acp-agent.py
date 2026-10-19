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
import re
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
    model = None
    quiet = None  # a GOQUIET prompt's id, answered at session/cancel
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
            if model:
                text += ", model " + model
            prompt = "".join(p.get("text", "") for p in params.get("prompt") or [])
            # GOQUIET: start, then say nothing until session/cancel (#27's
            # idle timeout), which ends the turn as cancelled.
            if "GOQUIET" in prompt:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Thinking..."}}}})
                quiet = mid
                continue
            if "PERMS" in prompt:
                # Ask permission for a read and an edit, the way Copilot
                # does mid-turn, and report which option each got.
                picked = {}
                for n, kind in enumerate(("read", "edit")):
                    send({"jsonrpc": "2.0", "id": "perm-{0}".format(n), "method": "session/request_permission",
                          "params": {"sessionId": params.get("sessionId"), "toolCall": {
                              "toolCallId": "t{0}".format(n), "title": kind + " a file", "kind": kind},
                              "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                                          {"optionId": "no", "name": "Deny", "kind": "reject_once"}]}})
                    for reply in sys.stdin:
                        reply = json.loads(reply)
                        if reply.get("id") == "perm-{0}".format(n):
                            picked[kind] = ((reply.get("result") or {}).get("outcome") or {}).get("optionId")
                            break
                text += ", perms: read={0} edit={1}".format(picked.get("read"), picked.get("edit"))
            # USAGE: report the context and a cumulative cost, as ACP's
            # usage_update does ($0.05 more each time).
            if "USAGE" in prompt:
                usage_cost = round(globals().get("usage_cost", 0) + 0.05, 2)
                globals()["usage_cost"] = usage_cost
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                      "update": {"sessionUpdate": "usage_update", "used": 50000, "size": 200000,
                                 "cost": {"amount": usage_cost, "currency": "USD"}}}})
            # TOOLS: one of azure-vicli's own tools (as Copilot titles MCP
            # tools: <server>-<tool>) and one of its own.
            if "TOOLS" in prompt:
                for n, title in enumerate(["azure-vicli-get_pull_request", "Read src/a.cs"]):
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                          "update": {"sessionUpdate": "tool_call", "toolCallId": "tl{0}".format(n), "title": title,
                                     "kind": "read", "status": "completed"}}})
            # EXEC=<command, _ for spaces>: ask to run it, report the option.
            for n, cmd in enumerate(re.findall(r"EXEC=(\S+)", prompt)):
                cmd = cmd.replace("_", " ")
                send({"jsonrpc": "2.0", "id": "exec-{0}".format(n), "method": "session/request_permission",
                      "params": {"sessionId": params.get("sessionId"), "toolCall": {
                          "toolCallId": "x{0}".format(n), "title": cmd, "kind": "execute",
                          "rawInput": {"command": cmd}},
                          "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                                      {"optionId": "no", "name": "Deny", "kind": "reject_once"}]}})
                for reply in sys.stdin:
                    reply = json.loads(reply)
                    if reply.get("id") == "exec-{0}".format(n):
                        opt = ((reply.get("result") or {}).get("outcome") or {}).get("optionId")
                        text += ", exec[{0}]={1}".format(cmd, opt)
                        break
            # EDITPATH=<path>: ask to edit that file, report the option.
            for n, path in enumerate(re.findall(r"EDITPATH=(\S+)", prompt)):
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {
                          "type": "text", "text": "Looking.\n\nI need {0} for the shared helper.\n\n".format(
                              path.rsplit("/", 1)[-1])}}}})
                send({"jsonrpc": "2.0", "id": "edit-{0}".format(n), "method": "session/request_permission",
                      "params": {"sessionId": params.get("sessionId"), "toolCall": {
                          "toolCallId": "e{0}".format(n), "title": "Edit " + path, "kind": "edit",
                          "locations": [{"path": path}]},
                          "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"},
                                      {"optionId": "no", "name": "Deny", "kind": "reject_once"}]}})
                for reply in sys.stdin:
                    reply = json.loads(reply)
                    if reply.get("id") == "edit-{0}".format(n):
                        opt = ((reply.get("result") or {}).get("outcome") or {}).get("optionId")
                        text += ", edit[{0}]={1}".format(path, opt)
                        break
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": params.get("sessionId"),
                  "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
            send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        elif method == "session/set_config_option":
            if params.get("configId") == "model":
                model = params.get("value")
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif method == "session/cancel":
            if quiet is not None:
                send({"jsonrpc": "2.0", "id": quiet, "result": {"stopReason": "cancelled"}})
                quiet = None
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})


if __name__ == "__main__":
    main()
