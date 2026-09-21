-- test-review-batch.lua: unit tests for review/batch.lua's pure
-- helpers - the ones that never touch vim/ctx, so they run directly under
-- plain luajit: M.tag (the winbar tag text), M.queue_thread/M.queue_reply/
-- M.remove_item (queue add/remove/serialise), M.item_args (the argv a
-- queued item submits with), and M.submit (sequential submission order
-- against a fake run_write, a failed item staying queued while the rest
-- confirm, and the vote being sent last and only when chosen).
--
-- Usage: luajit test-review-batch.lua <review/batch.lua path>

local path = arg[1]
assert(path, "usage: luajit test-review-batch.lua <review/batch.lua path>")
local M = dofile(path)

local fails = 0
local function check(name, ok)
  print((ok and "ok  " or "FAIL") .. "  " .. name)
  if not ok then fails = fails + 1 end
end

-- --- tag ----------------------------------------------------------------

do
  check("tag: off -> empty", M.tag({ on = false, items = {} }) == "")
  check("tag: nil state -> empty", M.tag(nil) == "")
  check("tag: on, empty queue", M.tag({ on = true, items = {} }) == "  [batch: 0]")
  check("tag: on, 3 queued", M.tag({ on = true, items = { {}, {}, {} } }) == "  [batch: 3]")
end

-- --- queue_thread / queue_reply / remove_item -----------------------------

do
  local state = { on = true, items = {} }
  local item = M.queue_thread(state, {
    args = { "--post", "src/foo.cs", "R", "10", "looks off" },
    bucket = "line", where = "src/foo.cs\tR\t10", path = "src/foo.cs",
    side = "R", lineno = 10, end_lineno = nil, text = "looks off", label = "Comment on src/foo.cs R:10",
  })
  check("queue_thread: appended", #state.items == 1 and state.items[1] == item)
  check("queue_thread: kind", item.kind == "thread")
  check("queue_thread: fields carried through", item.path == "src/foo.cs" and item.side == "R"
    and item.lineno == 10 and item.text == "looks off" and item.bucket == "line")
  check("queue_thread: args carried through", item.args[1] == "--post" and item.args[5] == "looks off")

  local comment = { author = "Me", content = "sounds good", pending = true }
  local ritem = M.queue_reply(state, { thread_id = 42, text = "sounds good", comment = comment })
  check("queue_reply: appended after thread item", #state.items == 2 and state.items[2] == ritem)
  check("queue_reply: kind", ritem.kind == "reply")
  check("queue_reply: fields carried through", ritem.thread_id == 42 and ritem.text == "sounds good"
    and ritem.comment == comment)

  local removed = M.remove_item(state, item)
  check("remove_item: returns true for a present item", removed == true)
  check("remove_item: queue now holds only the reply item", #state.items == 1 and state.items[1] == ritem)

  local removed_again = M.remove_item(state, item)
  check("remove_item: false for an item no longer in the queue", removed_again == false)
  check("remove_item: queue unchanged by a no-op removal", #state.items == 1)
end

-- --- item_args -------------------------------------------------------------

do
  local args = M.item_args({ kind = "thread", args = { "--post", "a.cs", "R", "3", "hi" } })
  check("item_args: thread item returns its own args verbatim", args[1] == "--post" and args[2] == "a.cs"
    and args[3] == "R" and args[4] == "3" and args[5] == "hi" and #args == 5)
end

do
  local args = M.item_args({ kind = "reply", thread_id = 7, text = "thanks" })
  check("item_args: reply item builds --reply argv", args[1] == "--reply" and args[2] == "7" and args[3] == "thanks")
  check("item_args: reply argv has exactly 3 elements", #args == 3)
end

-- --- submit ------------------------------------------------------------------

-- A fake run_write matching ctx.run_write's shape (args, on_ok, on_fail).
-- Every call is synchronous (calls on_ok/on_fail immediately) - same style
-- as review/comments.lua's own tests - which exercises M.submit's
-- continuation-passing step() the same way an async jobstart-backed one
-- would, just without needing an event loop here.
local function fake_run_write(script, log)
  return function(args, on_ok, on_fail)
    log[#log + 1] = args
    local outcome = script(args)
    if outcome == nil or outcome == true then
      on_ok()
    else
      on_fail(tostring(outcome))
    end
  end
end

do
  -- Three items, all succeed, no vote: submitted in queue order, all three
  -- confirmed (removed from state.items), done() sees three ok results and
  -- a nil vote_err.
  local state = { on = true, items = {
    { kind = "thread", args = { "--post", "a.cs", "R", "1", "one" } },
    { kind = "thread", args = { "--post", "a.cs", "R", "2", "two" } },
    { kind = "reply", thread_id = 9, text = "three" },
  } }
  local log = {}
  local before_order, after_order = {}, {}
  local done_results, done_vote_err, done_called = nil, "unset", 0

  M.submit(state, fake_run_write(function() return true end, log), nil, {
    before = function(item) before_order[#before_order + 1] = item end,
    after = function(item, ok) after_order[#after_order + 1] = { item = item, ok = ok } end,
    done = function(results, vote_err) done_results, done_vote_err, done_called = results, vote_err, done_called + 1 end,
  })

  check("submit (all ok): every write attempted", #log == 3)
  check("submit (all ok): submitted in queue order", log[1][4] == "1" and log[2][4] == "2" and log[3][1] == "--reply")
  check("submit (all ok): before() ran in order", #before_order == 3 and before_order[3].kind == "reply")
  check("submit (all ok): after() reports ok for every item", #after_order == 3
    and after_order[1].ok and after_order[2].ok and after_order[3].ok)
  check("submit (all ok): confirmed items removed from the queue", #state.items == 0)
  check("submit (all ok): done() called exactly once", done_called == 1)
  check("submit (all ok): done() results in order, all ok", done_results and #done_results == 3
    and done_results[1].ok and done_results[2].ok and done_results[3].ok)
  check("submit (all ok): no vote -> nil vote_err, no --vote sent", done_vote_err == nil
    and log[3][1] ~= "--vote" and #log == 3)
end

do
  -- Middle item fails: it stays in the queue (not removed), the other two
  -- are confirmed and removed, and results/after() report ok/fail correctly
  -- for each - this is the scenario the task calls out explicitly.
  local first = { kind = "thread", args = { "--post", "a.cs", "R", "1", "one" } }
  local second = { kind = "thread", args = { "--post", "a.cs", "R", "2", "two" } }
  local third = { kind = "reply", thread_id = 9, text = "three" }
  local state = { on = true, items = { first, second, third } }
  local log = {}

  local run_write = fake_run_write(function(args)
    if args[4] == "2" then return "network error" end
    return true
  end, log)

  local done_results
  M.submit(state, run_write, nil, {
    done = function(results) done_results = results end,
  })

  check("submit (one fails): all three attempted", #log == 3)
  check("submit (one fails): failed item stays queued", #state.items == 1 and state.items[1] == second)
  check("submit (one fails): succeeded items removed", state.items[1] ~= first and state.items[1] ~= third)
  check("submit (one fails): results in submission order", done_results[1].item == first
    and done_results[2].item == second and done_results[3].item == third)
  check("submit (one fails): first/third ok", done_results[1].ok == true and done_results[3].ok == true)
  check("submit (one fails): second failed with its message", done_results[2].ok == false
    and done_results[2].err == "network error")
end

do
  -- A vote is sent last, strictly after every item, and only when chosen.
  local state = { on = true, items = {
    { kind = "thread", args = { "--post", "a.cs", "R", "1", "one" } },
  } }
  local log = {}
  local run_write = fake_run_write(function() return true end, log)
  local vote_err_seen = "unset"
  M.submit(state, run_write, { key = "10", label = "Approve" }, {
    done = function(_, vote_err) vote_err_seen = vote_err end,
  })
  check("submit+vote: item write happened first", log[1][1] == "--post")
  check("submit+vote: vote sent last", log[2][1] == "--vote" and log[2][2] == "10")
  check("submit+vote: exactly two writes (item + vote)", #log == 2)
  check("submit+vote: vote_err nil on success", vote_err_seen == nil)
end

do
  -- No items, only a vote: the vote still goes out (submit is called with a
  -- vote regardless of queue size in the real gS flow's "no queued items to
  -- submit" guard being the caller's job, not M.submit's).
  local state = { on = true, items = {} }
  local log = {}
  local run_write = fake_run_write(function() return "vote failed" end, log)
  local vote_err_seen
  M.submit(state, run_write, { key = "-10", label = "Reject" }, {
    done = function(_, vote_err) vote_err_seen = vote_err end,
  })
  check("submit (no items, vote fails): only the vote was sent", #log == 1 and log[1][1] == "--vote")
  check("submit (no items, vote fails): vote_err surfaced", vote_err_seen == "vote failed")
end

do
  -- No items, no vote: done() still runs, with empty results and a nil vote_err.
  local state = { on = true, items = {} }
  local log = {}
  local run_write = fake_run_write(function() return true end, log)
  local results, vote_err, called = nil, "unset", 0
  M.submit(state, run_write, nil, {
    done = function(r, ve) results, vote_err, called = r, ve, called + 1 end,
  })
  check("submit (nothing to do): run_write never called", #log == 0)
  check("submit (nothing to do): done() called once with empty results", called == 1 and #results == 0)
  check("submit (nothing to do): vote_err nil", vote_err == nil)
end

print(fails == 0 and "test-review-batch: all cases pass" or ("test-review-batch: " .. fails .. " unexpected"))
if fails > 0 then os.exit(1) end
