local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(vim.env.OBSIDIAN_TOOLS_MARKDOWN_PATH or (vim.fs.dirname(root) .. "/markdown-tools.nvim"))
local api, uv = vim.api, vim.uv
local T = require("obsidian_tools")
local U = require("obsidian_tools.util")
local checks = 0
local function eq(a, b)
  checks = checks + 1
  assert(vim.deep_equal(a, b), vim.inspect({ actual = a, expected = b }))
end
local function fails(callback, text)
  local ok, err = pcall(callback)
  eq(ok, false)
  if text then
    assert(tostring(err):find(text, 1, true), err)
  end
end
local temp = U.path(vim.fn.tempname())
vim.fn.mkdir(temp .. "/vault/.obsidian", "p")
local vault_path = temp .. "/vault"
local function write(path, raw)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write(raw)
  fd:close()
end
local function fixture(name, raw)
  local path = vault_path .. "/" .. name
  write(path, raw)
  return path
end
local source = fixture(
  "notes/alpha.md",
  '---\nid: alpha-id\naliases: ["Alpha, first", Alpha]\ntags:\n  - science\n---\n# Alpha\n## Heading\nBlock text ^block-a\n#inline-tag\n`#hidden [[missing]]`\n```md\n[[missing]]\n```\n'
)
local other = fixture(
  "notes/other.md",
  '# Other\n[[notes/alpha|Shown]]\n[heading](alpha.md#Heading)\n[ref][target]\n[target]: <alpha.md> "Title"\n`[[notes/alpha]]`\n```\n[[notes/alpha]]\n```\n'
)
fixture(
  "templates/daily.md",
  '---\nid: daily-note\naliases:\n  - "{{title}}"\ntags: [daily-notes]\n---\n# {{title}}\n{{date}} {{time}} {{custom}}\n'
)
fixture(".trash/skip.md", "# Skip")
fixture("assets/pixel.png", "fake fixture image")
fixture("notes/outgoing.md", "# Outgoing\n[image](../assets/pixel.png)\n[[notes/other]]\n")
local function open(path)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "markdown"
end
T.setup({
  workspaces = { { path = vault_path } },
  daily_notes = { template = "daily.md" },
  templates = { substitutions = { custom = "CUSTOM" } },
  note_id = function()
    return "fixed-id"
  end,
})
open(source)
eq(T.workspace().path, vault_path)
eq(T.workspace(temp .. "/outside.md"), nil)
eq(vim.fn.exists(":ObsidianTools"), 2)
assert(not package.loaded["obsidian_tools.index"], "setup must not scan a vault")
local snapshot = require("obsidian_tools.index").scan(T.workspace())
eq(#snapshot.notes, 3)
local alpha = snapshot.by_path[source]
eq(alpha.aliases, { "Alpha, first", "Alpha" })
eq(alpha.tags, { "inline-tag", "science" })
eq(alpha.blocks["block-a"], 9)
eq(#snapshot.by_path[other].links, 3)
local R = require("obsidian_tools.resolve")
eq(R.candidates(T.workspace(), snapshot, { target = "alpha-id", wiki = true }, other)[1].path, source)
eq(R.candidates(T.workspace(), snapshot, { target = "Alpha", wiki = true }, other)[1].path, source)
local target = R.candidates(T.workspace(), snapshot, { target = "notes/alpha#^block-a", wiki = true }, other)[1]
eq(R.location(target), 9)
eq(R.location(R.candidates(T.workspace(), snapshot, { target = "alpha.md#Heading" }, other)[1]), 8)
eq(
  R.candidates(T.workspace(), snapshot, { target = "../assets/pixel.png" }, source)[1].path,
  vault_path .. "/assets/pixel.png"
)
eq(#R.candidates(T.workspace(), snapshot, { target = "../../outside.md" }, source), 0)
local original = U.read(other).raw
local plan = T.plan_rename("notes/renamed")
eq(plan.references, 3)
local result = T.apply_rename(plan)
eq(result.path, vault_path .. "/notes/renamed.md")
eq(uv.fs_stat(source), nil)
eq(
  U.read(other).raw,
  original:gsub("notes/alpha|", "notes/renamed|"):gsub("%(alpha.md#", "(renamed.md#"):gsub("<alpha.md>", "<renamed.md>")
)
eq(api.nvim_buf_get_name(0), result.path)
assert(U.read(result.path).raw:find("id: alpha%-id"))

-- Failure injection after one replacement must restore all documents and remove reservations.
open(result.path)
local undo_plan = T.plan_rename("notes/again")
local old_rename, calls = uv.fs_rename, 0
uv.fs_rename = function(a, b)
  if a:find(".obsidian-tools-", 1, true) then
    calls = calls + 1
    if calls == 2 then
      return nil, "injected failure"
    end
  end
  return old_rename(a, b)
end
local ok, err = pcall(T.apply_rename, undo_plan)
uv.fs_rename = old_rename
eq(ok, false)
assert(err:find("injected failure"))
eq(U.read(result.path).raw, undo_plan.files[#undo_plan.files].before)
eq(uv.fs_stat(undo_plan.target), nil)
for _, file in ipairs(undo_plan.files) do
  eq(U.read(file.path).raw, file.before)
end
local stale = T.plan_rename("notes/stale")
write(other, U.read(other).raw .. "external edit\n")
fails(function()
  T.apply_rename(stale)
end, "changed after planning")
eq(uv.fs_stat(stale.target), nil)
open(other)
api.nvim_buf_set_lines(0, 0, 0, false, { "unsaved" })
open(result.path)
fails(function()
  T.plan_rename("notes/dirty")
end, "Save modified")
vim.cmd("buffer! " .. vim.fn.bufnr(other))
vim.cmd("edit!")
open(result.path)
fails(function()
  T.plan_rename("../escape")
end, "escapes vault")
fails(function()
  T.plan_rename("notes/other")
end, "already exists")

-- Move updates outgoing relative links and preserves attachment targets.
open(vault_path .. "/notes/outgoing.md")
local move = T.plan_rename("notes/deeper/moved")
T.apply_rename(move)
assert(U.read(move.target).raw:find("../../assets/pixel.png", 1, true))
local symlink = vault_path .. "/linked"
assert(uv.fs_symlink(temp, symlink))
fails(function()
  T.plan_rename("linked/escape")
end, "Symlink escapes")

local W = require("obsidian_tools.workflows")
local daily = W.daily(T.workspace(), "2026-11-07")
local text = U.read(daily).raw
assert(text:find('id: "2026%-11%-07"'))
assert(text:find("CUSTOM"))
eq(W.daily(T.workspace(), "2026-11-07"), daily)
fails(function()
  W.daily(T.workspace(), "2026-02-30")
end, "Invalid calendar")
local new = W.new(T.workspace(), "中文 note")
eq(new, vault_path .. "/notes/fixed-id.md")
eq(W.new(T.workspace(), "another"), vault_path .. "/notes/fixed-id-2.md")
eq(W.templates(T.workspace()), { "daily.md" })
fails(function()
  W.template(T.workspace(), "../../notes/other.md", {})
end, "escapes vault")

-- Reservation failures leave no empty target, and a concurrent creator is retained.
open(new)
local first_failure = T.plan_rename("notes/failure-first")
local fs_rename = uv.fs_rename
uv.fs_rename = function()
  return nil, "first replacement failed"
end
local first_ok = pcall(T.apply_rename, first_failure)
uv.fs_rename = fs_rename
eq(first_ok, false)
eq(uv.fs_stat(first_failure.target), nil)
eq(U.read(new).raw, first_failure.files[1].before)
local collision = T.plan_rename("notes/concurrent")
local fs_open = uv.fs_open
uv.fs_open = function(path, flags, mode)
  if path == collision.target and flags == "wx" then
    write(path, "concurrent creator\n")
    return nil, "EEXIST"
  end
  return fs_open(path, flags, mode)
end
local collision_ok = pcall(T.apply_rename, collision)
uv.fs_open = fs_open
eq(collision_ok, false)
eq(U.read(collision.target).raw, "concurrent creator\n")
uv.fs_unlink(collision.target)
local daily_aliases = require("obsidian_tools.note").metadata(vim.split(text, "\n", { plain = true })).aliases
assert(vim.tbl_contains(daily_aliases, "2026-11-07"))
assert(vim.tbl_contains(daily_aliases, "November 7, 2026"))

-- Ambiguous basenames require an explicit selection and cannot be silently rewritten.
local duplicate_a = fixture("one/duplicate.md", "# One\n")
local duplicate_b = fixture("two/duplicate.md", "# Two\n")
local reference = fixture("notes/ambiguous.md", "[[duplicate]]\n")
open(duplicate_a)
fails(function()
  T.plan_rename("one/changed")
end, "Ambiguous link")
open(reference)
local selected_candidates, select_before = nil, vim.ui.select
vim.ui.select = function(items, _, callback)
  selected_candidates = items
  callback(items[2])
end
assert(T.follow_link())
assert(vim.wait(3000, function()
  return api.nvim_buf_get_name(0) == duplicate_b
end))
vim.ui.select = select_before
eq(#selected_candidates, 2)
local setup_count = #api.nvim_get_autocmds({ group = "ObsidianTools" })
T.setup(T.info().options)
eq(#api.nvim_get_autocmds({ group = "ObsidianTools" }), setup_count)

-- Async refresh observes unsaved note metadata; cancelled work never publishes.
open(new)
api.nvim_buf_set_lines(0, 0, -1, false, { "# Unsaved heading", "#fresh-tag" })
local async
require("obsidian_tools.index").refresh(T.workspace(), function(value)
  async = value
end)
assert(vim.wait(3000, function()
  return async ~= nil
end))
eq(async.by_path[new].title, "Unsaved heading")
eq(async.by_path[new].tags, { "fresh-tag" })
local published = false
local cancel = require("obsidian_tools.index").refresh(T.workspace(), function()
  published = true
end)
cancel()
local completed = false
require("obsidian_tools.index").refresh(T.workspace(), function()
  completed = true
end)
assert(vim.wait(3000, function()
  return completed
end))
eq(published, false)

-- Completion targets whole wiki content, including preinserted closing brackets.
api.nvim_buf_set_lines(0, 0, -1, false, { "[[Al]]" })
local provider = require("obsidian_tools.completion").new()
local ctx = {
  bufnr = api.nvim_get_current_buf(),
  filetype = "markdown",
  mode = "insert",
  row = 0,
  col = 4,
  before = "[[Al",
  line = "[[Al]]",
}
assert(provider.trigger(ctx))
local response
provider.complete(ctx, function(value)
  response = value
end)
assert(vim.wait(3000, function()
  return response
end))
local candidate = vim.iter(response.items):find(function(item)
  return item.detail == "notes/renamed.md"
end)
assert(candidate)
eq(candidate.textEdit.range.start.character, 2)
eq(candidate.textEdit.range["end"].character, 6)
assert(candidate.textEdit.newText:find("notes/renamed|", 1, true))
api.nvim_buf_set_lines(0, 0, -1, false, { "```", "[[Al", "```" })
ctx.row = 1
eq(provider.trigger(ctx), false)

-- Invalid setup retains registrations; dispose preserves user replacements.
fails(function()
  T.setup({ workspaces = "invalid" })
end)
eq(vim.fn.exists(":ObsidianTools"), 2)
api.nvim_buf_create_user_command(0, "ObsidianTools", function() end, {})
T.dispose()
eq(T.workspace(), nil)
eq(vim.fn.exists(":ObsidianTools"), 2)
api.nvim_buf_del_user_command(0, "ObsidianTools")
T.setup({ workspaces = { { path = vault_path } } })
vim.bo.filetype = "lua"
eq(vim.fn.exists(":ObsidianTools"), 0)
vim.bo.filetype = "markdown"
eq(vim.fn.exists(":ObsidianTools"), 2)
T.dispose()
vim.cmd("enew!")
vim.fn.delete(temp, "rf")
print("PASS obsidian-tools: " .. checks .. " assertions")
vim.cmd("qa!")
