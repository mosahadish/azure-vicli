-- tests/shot-skills.lua: the scene for docs/images/chat-skills.png - the
-- /skills popup over the chat, with a few made-up skills in a scratch home
-- folder (so their folders show as ~/...), two of them allowed.
local SKILLS = require("azure-cli.chat.skills")
local home = vim.fn.tempname()
local skills = {
  { "triage-pr-comments", "Sorts a PR's open threads into fix now, answer, and won't fix" },
  { "release-notes", "Writes release notes from the PRs merged since the last tag" },
  { "flaky-test-hunter", "Re-runs a failing test until it knows whether it's flaky, then says why" },
  { "sql-migration-check", "Checks a migration for locks, missing indexes and a way back" },
  { "deploy-check", "Checks a deployment's health endpoints and recent errors" },
}
for _, s in ipairs(skills) do
  local dir = home .. "/.copilot/skills/" .. s[1]
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "---", "name: " .. s[1], "description: " .. s[2], "---" }, dir .. "/SKILL.md")
end
local real_home = vim.env.HOME
vim.env.HOME = home
SKILLS.allow("triage-pr-comments")
SKILLS.allow("release-notes")
require("azure-cli.chat").show(false)
local win = SKILLS.popup(nil, function() end)
vim.env.HOME = real_home
if win then vim.api.nvim_win_set_cursor(win, { 5, 0 }) end
-- Clear the :luafile line this was run with (it names a local path).
vim.defer_fn(function() vim.cmd("echo \"\"") end, 300)
