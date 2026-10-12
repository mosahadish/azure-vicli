-- lua/azure-cli/chat/tools_code.lua: finding code across a whole repository,
-- the way the reviewer's gd does it - `git grep` and a pattern for what a
-- declaration looks like, no build or language server needed.
--
--   find_implementations  the types that implement an interface or derive
--                         from a class (`class X : Name`, `implements Name`,
--                         `extends Name`, `class X(Name)`), and with transitive (default)
--                         the types deriving from those in turn
--   find_definition       where a type or member is declared
--
-- Both search the fix/story worktree when there is one (uncommitted edits
-- included), else the local clone - at the PR's source branch for a PR.
--
-- Returns function(T) -> list of tools, T being chat/tools.lua. The pattern
-- builders and the hit parser are pure (tests/test-chat.lua).
local M = {}

local W = "[A-Za-z0-9_]"
local NOTW = "([^A-Za-z0-9_]|$)"

local function is_repo(p)
  return p ~= nil and p ~= "" and (vim.fn.isdirectory(p .. "/.git") == 1 or vim.fn.filereadable(p .. "/.git") == 1)
end

-- Escapes `name` for a POSIX ERE (dots in a qualified name, generics' <>).
local function ere(name)
  return (name:gsub("[%^%$%(%)%.%[%]%*%+%?{}|\\]", "\\%0"))
end

-- `git grep -E` patterns for a type deriving from / implementing `name`. Pure.
function M.implements_patterns(name)
  local n = ere(name)
  return {
    -- C#, C++, Kotlin, Swift: class Foo : Base, IName / class Foo<T> : IName<T>
    "(class|struct|record|interface|object)[[:space:]]+" .. W .. "+[^:;{]*:[^{;]*([[:space:],:]|^)([A-Za-z0-9_]+\\.)*"
      .. n .. NOTW,
    -- Java, TypeScript, PHP: extends Name / implements A, Name
    "(extends|implements)[[:space:]]+[^{;]*([[:space:],]|^)([A-Za-z0-9_]+\\.)*" .. n .. NOTW,
    -- Python: class Foo(Base, Name)
    "class[[:space:]]+" .. W .. "+[[:space:]]*[(]([^)]*[,[:space:]])?([A-Za-z0-9_]+\\.)*" .. n .. NOTW,
  }
end

-- Patterns for where `name` is declared: a type, or a member (a method,
-- property or field: a type or keyword, then the name, then ( { = ; or =>).
function M.definition_patterns(name)
  local n = ere(name)
  return {
    "(class|struct|record|interface|enum|delegate|trait|protocol|type)[[:space:]]+" .. n .. NOTW,
    "(def|func|function|fn|sub)[[:space:]]+" .. n .. NOTW,
    W .. "[A-Za-z0-9_<>,?.]*(\\[\\])?[[:space:]]+" .. n .. "[[:space:]]*(<[^>]*>)?[[:space:]]*([(]|[{]|=>|=|;)",
  }
end

-- `git grep -n` output ("[ref:]path:line:text") as hits. Lines that only
-- call or construct `name` (return x.Name(...), new Name(...)) are dropped
-- when `defs` is set. Pure.
function M.parse_hits(out, ref, name, defs)
  local hits = {}
  for line in (out or ""):gmatch("[^\n]+") do
    if ref and line:sub(1, #ref + 1) == ref .. ":" then line = line:sub(#ref + 2) end
    local path, lnum, text = line:match("^(.-):(%d+):(.*)$")
    if path then
      local t = vim.trim(text)
      local skip = defs and (t:match("^return%s") or t:match("^await%s") or t:find("new%s+" .. name:gsub("%p", "%%%0"))
        or t:find("[%.>]" .. name:gsub("%p", "%%%0") .. "%s*%(") or t:match("^//") or t:match("^%*") or t:match("^#"))
      if not skip then
        if #t > 200 then t = t:sub(1, 197) .. "..." end
        hits[#hits + 1] = { file = path, line = tonumber(lnum), text = t }
      end
    end
  end
  return hits
end

-- The type a hit declares ("public sealed class AcsGripper : ..." ->
-- "AcsGripper"), for following derived types further. Pure.
function M.declared_type(text)
  return text:match("class%s+([%w_]+)") or text:match("struct%s+([%w_]+)") or text:match("record%s+([%w_]+)")
    or text:match("interface%s+([%w_]+)") or text:match("object%s+([%w_]+)")
end

setmetatable(M, { __call = function(_, T)
  -- Where to search: dir, ref (nil = the working tree), label.
  local function where(args)
    local FIX = require("azure-cli.chat.tools_fix")
    if args.work_item_id then
      local d = FIX.find_story(args.work_item_id)
      if d then return d, nil, "#" .. tostring(args.work_item_id) .. "'s worktree" end
    end
    if args.pr_id then
      local pr = T.pr_record(args.pr_id)
      if not pr then return nil, nil, nil, "PR !" .. tostring(args.pr_id) .. " isn't known yet - call get_pull_request first" end
      if is_repo(FIX.path(pr)) then return FIX.path(pr), nil, "PR !" .. pr.id .. "'s fix worktree" end
      local clone = T.clone_path(pr)
      if is_repo(clone) then return clone, "origin/" .. tostring(pr.source), "PR !" .. pr.id .. " (" .. tostring(pr.source) .. ")" end
      return nil, nil, nil, "PR !" .. pr.id .. "'s repository isn't cloned locally"
    end
    if args.repo then
      local _, _, clone = T.repo_location(args.repo)
      if is_repo(clone) then return clone, nil, args.repo end
      return nil, nil, nil, args.repo .. " isn't cloned locally"
    end
    return nil, nil, nil, "say where to look: work_item_id (its story), pr_id or repo"
  end

  -- git grep for any of `patterns`: cb(hits).
  local function grep(dir, ref, patterns, name, defs, cb)
    local argv = { "git", "-C", dir, "grep", "-n", "-I", "-E" }
    if not ref then argv[#argv + 1] = "--untracked" end
    for _, p in ipairs(patterns) do vim.list_extend(argv, { "-e", p }) end
    if ref then argv[#argv + 1] = ref end
    T.git(argv, function(_, out) cb(M.parse_hits(out, ref, name, defs)) end)
  end

  local where_props = {
    work_item_id = { type = "integer", description = "search that story's worktree" },
    pr_id = { type = "integer", description = "search that PR's fix worktree, else its source branch" },
    repo = { type = "string", description = "search that repository's local clone" },
  }

  return {
    {
      name = "find_implementations",
      description = "Finds the types that implement an interface or derive from a class (e.g. every IGripper), "
        .. "across the whole repository, and with transitive=true (default) the types deriving from those too. "
        .. "Text-based (git grep for `class X : Name`, `implements Name`, `extends Name`): a base list split "
        .. "over several lines can be missed. Say where with work_item_id, pr_id or repo.",
      schema = { type = "object", properties = vim.tbl_extend("force", where_props, {
        name = { type = "string", description = "the interface or base class, e.g. IGripper" },
        transitive = { type = "boolean" },
      }), required = { "name" } },
      risk = "read",
      run = function(args, _, done)
        local dir, ref, label, why = where(args)
        if not dir then return done(nil, why) end
        local found, seen, queue = {}, { [args.name] = true }, { { name = args.name, depth = 0 } }
        local function step()
          local item = table.remove(queue, 1)
          if not item or #found >= 300 then
            return done({ searched = label, name = args.name, count = #found, implementations = found })
          end
          grep(dir, ref, M.implements_patterns(item.name), item.name, false, function(hits)
            for _, h in ipairs(hits) do
              local ty = M.declared_type(h.text)
              if ty and ty ~= item.name then
                h.type, h.via = ty, item.depth > 0 and item.name or nil
                found[#found + 1] = h
                if args.transitive ~= false and not seen[ty] and item.depth < 4 then
                  seen[ty] = true
                  queue[#queue + 1] = { name = ty, depth = item.depth + 1 }
                end
              end
            end
            step()
          end)
        end
        step()
      end,
    },
    {
      name = "find_definition",
      description = "Finds where a type or member (class, interface, method, property, field) is declared, across "
        .. "the whole repository. Text-based (git grep and a declaration pattern), so check the hits. Say where "
        .. "with work_item_id, pr_id or repo.",
      schema = { type = "object", properties = vim.tbl_extend("force", where_props, {
        name = { type = "string", description = "the name, e.g. AcsGripper or ValidateReadyForFlow" },
      }), required = { "name" } },
      risk = "read",
      run = function(args, _, done)
        local dir, ref, label, why = where(args)
        if not dir then return done(nil, why) end
        grep(dir, ref, M.definition_patterns(args.name), args.name, true, function(hits)
          if #hits > 50 then hits = vim.list_slice(hits, 1, 50) end
          done({ searched = label, name = args.name, count = #hits, definitions = hits })
        end)
      end,
    },
  }
end })

return M
