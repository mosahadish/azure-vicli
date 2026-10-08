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
  "fix it"  start_fix, an edit, show_fix, commit_and_push_fix on PR 101
  "implement"  start_story for work item 3001 (twice: the second reuses
            it), a new file, show_fix, commit_and_push_fix
  anything else: current_view only
It always reports the tools it saw, the model (--model) and whether it was
resumed (--resume ID).

Usage: fake-chat-agent.py --mcp-config FILE [--model M] [--resume ID]
"""
import json
import os
import subprocess
import sys
import time


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

    def call(name, args=None):
        text, err = mcp.call(name, args)
        out.append(name + ": " + text + (" (error)" if err else ""))
        return text, err

    out.append("selection: " + str(view.get("selection_lines")) + " " + str((view.get("selection") or "")[:40]))
    out.append("hunk: " + str(bool(view.get("hunk"))))
    out.append("refs: " + ("PR !102" in message and "Referenced in the message" in message and "yes" or "no"))
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
    elif "build fail" in asked:
        call("get_build_log", {"pr_id": 104})
    elif "show me" in asked:
        call("open_in_ui", {"pr_id": 101, "file": "src/throttle.py", "line": 4})
    elif "annotate" in asked:
        call("annotate_code", {"pr_id": 101, "file": "src/auth.py", "line": 12, "text": "Lockout check here", "kind": "warning"})
    elif "fix it" in asked:
        res = json.loads(call("start_fix", {"pr_id": 101})[0])
        path = os.path.join(res["directory"], "src", "auth.py")
        with open(path, "a", encoding="utf-8") as f:
            f.write("# FIXED-BY-AGENT\n")
        call("show_fix", {"pr_id": 101})
        call("commit_and_push_fix", {"pr_id": 101, "message": "Return a reason code on lockout"})
    elif "implement" in asked:
        res = json.loads(call("start_story", {"work_item_id": 3001, "repo": "widgets", "from": "main",
                                              "name": "feature/3001-story"})[0])
        with open(os.path.join(res["directory"], "STORY.md"), "w", encoding="utf-8") as f:
            f.write("IMPLEMENTED-BY-AGENT\n")
        with open(os.path.join(res["directory"], "SCRATCH.md"), "w", encoding="utf-8") as f:
            f.write("temporary\n")
        call("delete_fix_file", {"work_item_id": 3001, "path": "SCRATCH.md"})
        call("delete_fix_file", {"work_item_id": 3001, "path": "README.md"})
        call("delete_fix_file", {"work_item_id": 3001, "path": "../outside.txt"})
        call("start_story", {"work_item_id": 3001, "repo": "widgets", "from": "main", "name": "feature/3001-story"})
        call("show_fix", {"work_item_id": 3001})
        call("commit_and_push_fix", {"work_item_id": 3001, "message": "Implement the login throttle story"})
    elif "look up" in asked:
        call("get_pull_request", {"pr_id": 102})
        call("get_pr_threads", {"pr_id": 102})
        call("get_pull_request", {"pr_id": 9999})
        call("find_definition", {"pr_id": 101, "name": "is_locked"})
        call("find_implementations", {"repo": "widgets", "name": "Nothing"})
    elif "plan" in asked:
        call("create_child_task", {"parent_id": 3001, "title": "Write the lockout tests"})
        call("move_to_sprint", {"id": 3002, "sprint": "Sprint 43"})
        call("link_pr_to_work_item", {"pr_id": 102, "work_item_id": 3002})
    mcp.close()
    out.append("FAKE-CHAT-RAN")
    text = "\n".join("- " + l for l in out)
    session = opt("--resume") or "fake-chat-1"
    if "--stream" in args:
        # Claude Code's --output-format stream-json: events, one per line,
        # flushed as they happen; the answer arrives in two parts.
        def emit_event(ev):
            sys.stdout.write(json.dumps(ev) + "\n")
            sys.stdout.flush()
        emit_event({"type": "system", "subtype": "init", "session_id": session})
        emit_event({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Read", "input": {"file_path": "src/auth.py"}}]}})
        half = len(out) // 2
        emit_event({"type": "assistant", "message": {"content": [{"type": "text", "text": "\n".join("- " + l for l in out[:half])}]}})
        time.sleep(0.3)
        emit_event({"type": "assistant", "message": {"content": [{"type": "text", "text": "\n".join("- " + l for l in out[half:])}]}})
        emit_event({"type": "result", "subtype": "success", "result": text, "session_id": session})
        return
    print(json.dumps({"type": "result", "result": text, "session_id": session}))


if __name__ == "__main__":
    main()
