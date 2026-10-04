#!/usr/bin/env python3
"""tests/fake-chat-agent.py - a stand-in for Claude Code in the chat panel
(tests/demo-smoke.lua). It behaves like `claude -p --output-format json
--mcp-config <file>`: reads the message on stdin, starts the MCP server the
config names (azure-cli.py --mcp), speaks MCP to it over stdio, and prints a
JSON envelope {"result", "session_id"}.

What it does depends on the message:
  "triage"  current_view, get_pr_threads, then draft_reply on the first
            active thread
  "branch"  create_branch for the work item 3001 from main in widgets
  "vote"    vote approve on the PR in view (the plugin asks the user)
  anything else: current_view only
It always reports the tools it saw, the model (--model) and whether it was
resumed (--resume ID).

Usage: fake-chat-agent.py --mcp-config FILE [--model M] [--resume ID]
"""
import json
import subprocess
import sys


class Mcp:
    def __init__(self, server):
        self.proc = subprocess.Popen([server["command"]] + server.get("args", []), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, env=_env(server.get("env")))
        self.next_id = 0

    def request(self, method, params=None):
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("the MCP server exited")
            resp = json.loads(line)
            if resp.get("id") == self.next_id:
                return resp

    def notify(self, method):
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.proc.stdin.flush()

    def call(self, name, args=None):
        resp = self.request("tools/call", {"name": name, "arguments": args or {}})
        res = resp.get("result") or {}
        text = "".join(c.get("text", "") for c in res.get("content", []))
        return text, bool(res.get("isError"))

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def _env(extra):
    import os
    env = dict(os.environ)
    env.update(extra or {})
    return env


def main():
    args = sys.argv[1:]

    def opt(name):
        if name in args:
            return args[args.index(name) + 1]
        return None

    with open(opt("--mcp-config"), encoding="utf-8") as f:
        server = json.load(f)["mcpServers"]["azure-vicli"]
    message = sys.stdin.read()
    asked = message.split("## Message\n", 1)[-1].strip()
    out = ["model: " + str(opt("--model")), "resumed: " + str(opt("--resume"))]

    mcp = Mcp(server)
    init = mcp.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "fake-chat-agent", "version": "1"}})
    mcp.notify("notifications/initialized")
    tools = [t["name"] for t in mcp.request("tools/list")["result"]["tools"]]
    out.append("server: " + init["result"]["serverInfo"]["name"] + ", tools: " + str(len(tools)))
    view = json.loads(mcp.call("current_view")[0])
    out.append("view: {0}, PR {1}, file {2}, line {3}, thread {4}".format(
        view.get("screen"), (view.get("pr") or {}).get("id"), view.get("file"), view.get("line"),
        (view.get("thread") or {}).get("id")))
    out.append("message had the view: " + str("## Current view" in message))

    if "triage" in asked:
        pr = view["pr"]["id"]
        threads = json.loads(mcp.call("get_pr_threads", {"pr_id": pr})[0])
        active = [t for t in threads if t["status"] == "active"]
        out.append("threads: {0}, active: {1}".format(len(threads), len(active)))
        text, err = mcp.call("draft_reply", {"pr_id": pr, "thread_id": active[0]["id"],
                                             "text": "Agreed - a reason code it is."})
        out.append("draft: " + text + (" (error)" if err else ""))
    elif "branch" in asked:
        text, err = mcp.call("create_branch", {"repo": "widgets", "from": "main",
                                               "name": "feature/3001-throttle-login", "work_item_id": 3001})
        out.append("branch: " + text + (" (error)" if err else ""))
    elif "vote" in asked:
        text, err = mcp.call("vote", {"pr_id": view["pr"]["id"], "vote": "approve"})
        out.append("vote: " + text + (" (error)" if err else ""))
    mcp.close()
    out.append("FAKE-CHAT-RAN")
    print(json.dumps({"type": "result", "result": "\n".join("- " + l for l in out),
                      "session_id": opt("--resume") or "fake-chat-1"}))


if __name__ == "__main__":
    main()
