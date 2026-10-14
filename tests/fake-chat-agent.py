#!/usr/bin/env python3
"""tests/fake-chat-agent.py - a stand-in for Claude Code in the chat panel
(tests/demo-smoke.lua). It behaves like `claude -p --input-format
stream-json --output-format stream-json --mcp-config <file>`: starts the
MCP server the config names (azure-cli.py --mcp) once, then reads one
stream-json user message per line on stdin until it closes, speaks MCP to
the server for each, and answers each with stream-json events ending in a
"result" - the same process for the whole conversation.

What it does depends on the message:
  "triage"  current_view, get_pr_threads, then draft_reply on the first
            active thread
  "branch"  create_branch for the work item 3001 from main in widgets
  "vote"    vote approve on the PR in view (the plugin asks the user)
  "fix it"  start_fix, an edit, show_fix, commit_and_push_fix on PR 101
  "implement"  start_story for work item 3001 (twice: the second reuses
            it), a new file, show_fix, commit_and_push_fix
  "make a plan"  start_story for 3002 (refused: no plan yet), submit_plan,
            start_story again (refused: not approved yet)
  "About ..."  (a question from a plan / change-viewer line) answers
            "BECAUSE-<the quoted line>" and nothing else
  "revise the plan"  counts the line requests, submit_plan revision 3
  "Please change these in ..."  (the change viewer's gS) counts the lines
  "I approve the plan"  start_story for 3002, an edit, show_fix, run_tests
  "Make a plan for this ... Work item #N"  (an agent started from the board)
            waits a second, then submit_plan for #N
  "Make a plan for this ... GitHub issue #N"  (gP on the Issues board)
            get_work_item without a board (its view says github), then
            submit_plan for #N
  "work the issue"  (gq on the Issues board's #12) the board tools on
            GitHub: list, read, state, comment, a sub-issue, start_story in
            gizmos, create_pull_request closing #12, and linking gizmos#7
            to #13
  anything else: current_view only
It always reports the tools it saw, the model (--model) and which turn of
this process it is ("turn: 1" for a fresh process).

Usage: fake-chat-agent.py --mcp-config FILE [--model M]
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
    mcp = Mcp(server)
    init = mcp.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "fake-chat-agent", "version": "1"}})
    mcp.notify("notifications/initialized")
    session = "fake-chat-1"
    turn = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        turn += 1
        req = json.loads(line)
        message = req["message"]["content"][0]["text"]
        answer_turn(mcp, init, message, turn, opt("--model"), session)
    mcp.close()


def answer_turn(mcp, init, message, turn, model, session):
    asked = message.split("## Message\n", 1)[-1].strip()
    out = ["model: " + str(model), "turn: " + str(turn)]
    tools = [t["name"] for t in mcp.request("tools/list")["result"]["tools"]]
    out.append("server: " + init["result"]["serverInfo"]["name"] + ", tools: " + str(len(tools)))
    view = json.loads(mcp.call("current_view")[0])
    out.append("view: {0}, PR {1}, file {2}, line {3}, thread {4}".format(
        view.get("screen"), (view.get("pr") or {}).get("id"), view.get("file"), view.get("line"),
        (view.get("thread") or {}).get("id")))
    out.append("message had the view: " + str("## Current view" in message))
    out.append("message had the history: " + str("## The conversation so far" in message))

    def call(name, args=None):
        text, err = mcp.call(name, args)
        out.append(name + ": " + text + (" (error)" if err else ""))
        return text, err
    out.append("selection: " + str(view.get("selection_lines")) + " " + str((view.get("selection") or "")[:40]))
    out.append("hunk: " + str(bool(view.get("hunk"))))
    out.append("refs: " + ("PR !102" in message and "Referenced in the message" in message and "yes" or "no"))
    if asked.startswith("Make a plan for this") and "GitHub issue #" in asked:
        # gP on the Issues board: the agent's view names the board, so a
        # tool call without board= reads the GitHub issue.
        import re
        wid = int(re.search(r"GitHub issue #(\d+)", asked).group(1))
        item, err = mcp.call("get_work_item", {"id": wid})
        title = (json.loads(item).get("item") or {}).get("title") if not err else "ERROR " + item
        call("submit_plan", {"work_item_id": wid, "title": "Plan for issue {0}".format(wid), "markdown": "\n".join([
            "# Plan for issue {0}".format(wid), "", "## Goal", "G", "", "## Approach", "A", "", "## Files",
            "- `gizmo.py` - x"])})
        out[:] = ["planned issue #{0} on board {1}: {2}".format(wid, view.get("board"), title)]
    elif asked.startswith("Make a plan for this") and "Work item #" in asked:
        # One of several agents started from the board (chat/agents.lua):
        # slow enough that two would overlap, then the plan for its item.
        import re
        wid = int(re.search(r"Work item #(\d+)", asked).group(1))
        time.sleep(1)
        call("submit_plan", {"work_item_id": wid, "title": "Plan for {0}".format(wid), "markdown": "\n".join([
            "# Plan for {0}".format(wid), "", "## Goal", "G", "", "## Approach", "A", "", "## Files",
            "- `src/auth.py` - x"])})
        out[:] = ["planned #{0} as agent {1} in {2}".format(wid, os.environ.get("AZVICLI_CHAT_AGENT"),
                                                            os.path.basename(os.getcwd()))]
    elif asked.startswith("Make a plan for this") and "PR !" in asked:
        # An agent started for one PR's review comments (gP on the dashboard
        # or in the reviewer): the plan of the fix for that PR.
        import re
        pid = int(re.search(r"PR !(\d+)", asked).group(1))
        threads = re.search(r"in threads? ([\d, ]+)\.", asked)
        call("submit_plan", {"pr_id": pid, "title": "Fix the comments on {0}".format(pid), "markdown": "\n".join([
            "# Fix the comments on {0}".format(pid), "", "## Goal", "G", "", "## Approach", "A", "", "## Files",
            "- `src/auth.py` - x"])})
        out[:] = ["planned PR !{0} for {1}".format(pid, threads.group(1).strip() if threads else "every active thread")]
    elif "work the issue" in asked:
        # gq on the Issues board's #12: calls without board= go to GitHub
        # because the view says so; the rest name it.
        out.append("view board: {0}, item {1}".format(view.get("board"), (view.get("work_item") or {}).get("id")))
        call("list_work_items")
        call("list_work_items", {"board": "azure"})
        call("get_work_item", {"id": 12, "board": "github"})
        call("set_work_item_state", {"id": 12, "state": "In Progress"})
        call("comment_on_work_item", {"id": 12, "text": "Picking this up.", "board": "github"})
        call("create_child_task", {"parent_id": 12, "title": "Write the wobble test"})
        # No iteration given: the current one (Iteration 2); then one named.
        call("create_work_item", {"title": "Wobble at high speed", "body": "Seen on the test rig.", "board": "github"})
        call("create_work_item", {"title": "Document the wobble", "iteration": "Iteration 3", "board": "github"})
        call("list_work_items", {"board": "github", "sprint": "none"})
        # Azure's No sprint: the team's backlog iteration and the root.
        call("list_work_items", {"board": "azure", "sprint": "none"})
        res, err = call("start_story", {"work_item_id": 12, "repo": "gizmos", "from": "main",
                                        "name": "feature/12-wobble", "board": "github"})
        if not err:
            with open(os.path.join(json.loads(res)["directory"], "WOBBLE.md"), "w", encoding="utf-8") as f:
                f.write("clamped\n")
        call("create_pull_request", {"repo": "gizmos", "source": "feature/12-wobble", "target": "main",
                                     "title": "Clamp the wobble", "description": "Clamps it.", "work_item_ids": [12],
                                     "board": "github"})
        call("link_pr_to_work_item", {"pr_id": 7, "work_item_id": 13, "board": "github"})
    elif "I approve the plan" in asked:
        import re
        wid = int((re.search(r"I approve the plan for #(\d+)", asked) or re.search(r"(3002)", "3002")).group(1))
        out.append("answers: " + " | ".join(l for l in asked.splitlines() if l.startswith("- Should")))
        res = json.loads(call("start_story", {"work_item_id": wid, "repo": "widgets", "from": "main",
                                              "name": "feature/{0}-planned".format(wid)})[0])
        path = os.path.join(res["directory"], "src", "auth.py")
        with open(path, "a", encoding="utf-8") as f:
            f.write("PLANNED_CHANGE = True\n")
        with open(path, encoding="utf-8") as f:
            line = len(f.read().splitlines())
        # Line 7 of the plan is "Return a reason code from login().".
        call("show_fix", {"work_item_id": wid, "steps": [
            {"file": "src/auth.py", "line": line, "plan_line": 7, "note": "the reason code"},
            {"file": "src/auth.py", "line": 1, "plan_line": 999}]})
        call("run_tests", {"work_item_id": wid})
        out.append("implemented #{0}".format(wid))
    elif asked.startswith("About "):
        quoted = [l[2:] for l in asked.splitlines() if l.startswith("> ")]
        out[:] = ["BECAUSE-" + (quoted[-1] if quoted else "?") + " (asked on the " + str(view.get("screen")) + ", line "
                  + str(view.get("plan_line") or view.get("line")) + ")"]
    elif asked.startswith("Please change these in "):
        out[:] = ["fix requests: " + str(sum(1 for l in asked.splitlines() if l.startswith("- src/")))]
    elif "revise the plan" in asked:
        out.append("requests: " + str(sum(1 for l in asked.splitlines() if l.startswith("- line "))))
        call("submit_plan", {"work_item_id": 3002, "title": "Lockout reason codes", "markdown": "\n".join([
            "# Lockout reason codes", "", "## Goal", "Say why a login was refused.", "",
            "## Approach", "Return a reason code from login().", "Keep the boolean API as a thin wrapper.", "",
            "## Files", "- `src/auth.py` - the reason code", "- `src/throttle.py` - expose the lockout state", "",
            "## Risks", "Callers comparing to True.", "", "## Test plan", "A test per reason.", "```sh",
            "grep -q PLANNED_CHANGE src/auth.py", "```", "", "## Open questions", "- Should admins be exempt?"])})
    elif "make a plan" in asked:
        call("start_story", {"work_item_id": 3002, "repo": "widgets", "from": "main", "name": "feature/3002-planned"})
        call("submit_plan", {"work_item_id": 3002, "title": "Lockout reason codes", "markdown": "\n".join([
            "# Lockout reason codes", "", "## Goal", "Say why a login was refused.", "",
            "## Approach", "Return a reason code from login().", "Keep the boolean API as a wrapper.", "",
            "## Files", "- `src/auth.py` - the reason code", "- `src/throttle.py` - expose the lockout state", "",
            "## Risks", "Callers comparing to True.", "", "## Test plan", "A test per reason.", "```sh",
            "grep -q PLANNED_CHANGE src/auth.py", "```"])})
        call("start_story", {"work_item_id": 3002, "repo": "widgets", "from": "main", "name": "feature/3002-planned"})
    elif "triage" in asked:
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
        call("create_work_item", {"title": "Lockout emails go to spam", "body": "Reported by support.\nTwice.",
                                  "type": "Bug", "iteration": "Sprint 43", "board": "azure"})
        call("move_to_sprint", {"id": 3002, "sprint": "Sprint 43"})
        call("link_pr_to_work_item", {"pr_id": 102, "work_item_id": 3002})
    out.append("FAKE-CHAT-RAN")
    text = "\n".join("- " + l for l in out)

    # Claude Code's --output-format stream-json: events, one per line,
    # flushed as they happen; the answer arrives in two parts.
    def emit_event(ev):
        sys.stdout.write(json.dumps(ev) + "\n")
        sys.stdout.flush()
    if turn == 1:
        emit_event({"type": "system", "subtype": "init", "session_id": session})
    emit_event({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Read", "input": {"file_path": "src/auth.py"}}]}})
    half = len(out) // 2
    emit_event({"type": "assistant", "message": {"content": [{"type": "text", "text": "\n".join("- " + l for l in out[:half])}]}})
    time.sleep(0.3)
    emit_event({"type": "assistant", "message": {"content": [{"type": "text", "text": "\n".join("- " + l for l in out[half:])}]}})
    emit_event({"type": "result", "subtype": "success", "result": text, "session_id": session})


if __name__ == "__main__":
    main()
