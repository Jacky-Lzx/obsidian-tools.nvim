local M = {}
local api, U = vim.api, require("obsidian_tools.util")
local config = require("obsidian_tools.config").normalize()
local generation, group, commands = 0, nil, {}
local active = false
local actions = {
  "quick_switch",
  "new",
  "daily",
  "dailies",
  "search",
  "tags",
  "backlinks",
  "follow_link",
  "link",
  "template",
  "rename",
  "refresh",
  "info",
}
local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO, { title = "Obsidian tools" })
end
local function safe(callback, ...)
  local ok, a, b = xpcall(callback, debug.traceback, ...)
  if not ok then
    notify(a, vim.log.levels.ERROR)
    return false, a
  end
  return a, b
end
function M.workspace(file)
  if not active then
    return
  end
  return require("obsidian_tools.config").workspace(config, file)
end
local function context()
  local buf = api.nvim_get_current_buf()
  local file = api.nvim_buf_get_name(buf)
  local vault = assert(M.workspace(file), "Current file is outside configured vaults")
  return {
    buf = buf,
    file = file,
    win = api.nvim_get_current_win(),
    vault = vault,
    tick = api.nvim_buf_get_changedtick(buf),
    generation = generation,
  }
end
local function valid(ctx)
  return ctx.generation == generation
    and api.nvim_buf_is_valid(ctx.buf)
    and api.nvim_buf_get_changedtick(ctx.buf) == ctx.tick
    and api.nvim_win_is_valid(ctx.win)
end
local function in_origin(ctx, callback)
  if not valid(ctx) then
    return
  end
  api.nvim_set_current_win(ctx.win)
  safe(callback)
end
local function refresh(ctx, callback)
  return require("obsidian_tools.index").refresh(ctx.vault, function(index)
    if valid(ctx) then
      safe(callback, index)
    end
  end)
end
local function pick(ctx, items, prompt, format, callback)
  return vim.ui.select(items, { prompt = prompt, format_item = format }, function(item)
    if item then
      -- Let the previous picker finish restoring focus/mode before opening a child.
      vim.schedule(function()
        in_origin(ctx, function()
          callback(item)
        end)
      end)
    end
  end)
end
local function note_label(note)
  return note.title .. "  [" .. note.relative .. "]"
end
local function open_candidate(candidate)
  if not candidate.note then
    local _, err = vim.ui.open(candidate.path)
    assert(not err, err)
  else
    local row, col = require("obsidian_tools.resolve").location(candidate)
    assert(row, col)
    U.open(candidate.path, row, col)
  end
end
function M.quick_switch(query)
  local ctx = context()
  return refresh(ctx, function(index)
    local items = index.notes
    if query and query ~= "" then
      local needle = vim.fn.tolower(query)
      items = vim.tbl_filter(function(note)
        return vim.fn.tolower(note_label(note)):find(needle, 1, true) ~= nil
      end, items)
    end
    pick(ctx, items, "Obsidian notes", note_label, function(note)
      U.open(note.path)
    end)
  end)
end
function M.new(title)
  local ctx = context()
  local function create(value)
    if value and vim.trim(value) ~= "" then
      in_origin(ctx, function()
        U.open(require("obsidian_tools.workflows").new(ctx.vault, value))
      end)
    end
  end
  if title and title ~= "" then
    return create(title)
  end
  return vim.ui.input({ prompt = "New note title: " }, create)
end
function M.daily(date)
  local ctx = context()
  return U.open(require("obsidian_tools.workflows").daily(ctx.vault, date))
end
function M.dailies()
  local ctx = context()
  local prefix = ctx.vault.config.daily_notes.folder .. "/"
  return refresh(ctx, function(index)
    local notes = vim.tbl_filter(function(note)
      return vim.startswith(note.relative, prefix)
    end, index.notes)
    table.sort(notes, function(a, b)
      return a.relative > b.relative
    end)
    pick(ctx, notes, "Daily notes", note_label, function(note)
      U.open(note.path)
    end)
  end)
end
function M.search(query)
  local ctx = context()
  local function search(value)
    if value == nil or value == "" then
      return
    end
    refresh(ctx, function(index)
      local needle, items = vim.fn.tolower(value), {}
      for _, note in ipairs(index.notes) do
        for row, line in ipairs(note.doc.lines) do
          if vim.fn.tolower(line):find(needle, 1, true) then
            items[#items + 1] = { note = note, row = row, text = line }
          end
        end
      end
      pick(ctx, items, "Search notes: " .. value, function(item)
        return item.note.relative .. ":" .. item.row .. "  " .. item.text
      end, function(item)
        U.open(item.note.path, item.row)
      end)
    end)
  end
  if query and query ~= "" then
    return search(query)
  end
  return vim.ui.input({ prompt = "Search notes: " }, search)
end
function M.tags(tag)
  local ctx = context()
  return refresh(ctx, function(index)
    local function notes(value)
      local items = vim.tbl_filter(function(note)
        return vim.tbl_contains(note.tags, value)
      end, index.notes)
      pick(ctx, items, "Tag: #" .. value, note_label, function(note)
        U.open(note.path)
      end)
    end
    if tag and tag ~= "" then
      return notes(tag:gsub("^#", ""))
    end
    local all = {}
    for _, note in ipairs(index.notes) do
      for _, value in ipairs(note.tags) do
        all[value] = true
      end
    end
    local tags = vim.tbl_keys(all)
    table.sort(tags)
    pick(ctx, tags, "Obsidian tags", function(value)
      return "#" .. value
    end, notes)
  end)
end
function M.backlinks()
  local ctx = context()
  return refresh(ctx, function(index)
    local items = {}
    for _, note in ipairs(index.notes) do
      for _, link in ipairs(note.links) do
        local candidates = require("obsidian_tools.resolve").candidates(ctx.vault, index, link, note.path)
        if candidates and #candidates == 1 and candidates[1].path == ctx.file then
          items[#items + 1] = { note = note, row = link.row, text = note.doc.lines[link.row] }
        end
      end
    end
    pick(ctx, items, "Backlinks", function(item)
      return item.note.relative .. ":" .. item.row .. "  " .. item.text
    end, function(item)
      U.open(item.note.path, item.row)
    end)
  end)
end
function M.follow_link(link, source)
  local file = source and source.file or api.nvim_buf_get_name(0)
  if not M.workspace(file) then
    return nil
  end
  link = link or require("markdown_tools").link_at()
  if not link then
    return false, "No link under cursor"
  end
  if require("obsidian_tools.resolve").parts(link) == nil then
    return nil
  end
  local ctx = context()
  refresh(ctx, function(index)
    local candidates = require("obsidian_tools.resolve").candidates(ctx.vault, index, link, ctx.file)
    assert(candidates and #candidates > 0, "Unresolved vault link: " .. link.target)
    if #candidates == 1 then
      in_origin(ctx, function()
        open_candidate(candidates[1])
      end)
    else
      pick(ctx, candidates, "Choose linked note", function(item)
        return U.relative(ctx.vault.path, item.path)
      end, open_candidate)
    end
  end)
  return true
end
function M.link()
  local ctx = context()
  return refresh(ctx, function(index)
    pick(ctx, index.notes, "Insert note link", note_label, function(note)
      local target = require("obsidian_tools.resolve").target(ctx.vault, note.path, ctx.file, true)
      local label = note.title:gsub("[|%[%]\r\n]", "")
      api.nvim_put({ "[[" .. target .. "|" .. label .. "]]" }, "c", true, true)
    end)
  end)
end
function M.template(name)
  local ctx = context()
  local workflow = require("obsidian_tools.workflows")
  if name and name ~= "" then
    return workflow.insert_template(ctx.vault, name)
  end
  return pick(ctx, workflow.templates(ctx.vault), "Insert template", tostring, function(value)
    workflow.insert_template(ctx.vault, value)
  end)
end
function M.plan_rename(destination)
  local ctx = context()
  return require("obsidian_tools.rename").plan(ctx.vault, ctx.file, destination)
end
function M.apply_rename(plan)
  return require("obsidian_tools.rename").apply(plan)
end
function M.rename(destination)
  local ctx = context()
  local function rename(value)
    if not value or value == "" then
      return
    end
    in_origin(ctx, function()
      local plan = M.plan_rename(value)
      local result = M.apply_rename(plan)
      notify(("Renamed note; updated %d links in %d files"):format(result.references, result.files))
    end)
  end
  if destination and destination ~= "" then
    return rename(destination)
  end
  return vim.ui.input(
    { prompt = "Rename/move note (vault-relative): ", default = U.relative(ctx.vault.path, ctx.file) },
    rename
  )
end
function M.refresh()
  local ctx = context()
  return refresh(ctx, function(index)
    notify(("Indexed %d notes; %d read errors"):format(#index.notes, #index.errors))
  end)
end
function M.info()
  return { workspace = M.workspace(), options = vim.deepcopy(config) }
end
function M.menu()
  local ctx = context()
  return pick(ctx, actions, "Obsidian Commands", tostring, function(action)
    safe(M[action])
  end)
end
function M.command(args)
  local action, rest = args:match("^(%S+)%s*(.*)$")
  if not action then
    return M.menu()
  end
  assert(vim.tbl_contains(actions, action), "Unknown Obsidian action: " .. action)
  if action == "info" then
    return notify(vim.inspect(M.info()))
  end
  return M[action](rest ~= "" and rest or nil)
end
local function detach(buf)
  local owned = commands[buf]
  if owned and api.nvim_buf_is_valid(buf) then
    local current = api.nvim_buf_get_commands(buf, {}).ObsidianTools
    if vim.deep_equal(current, owned) then
      api.nvim_buf_del_user_command(buf, "ObsidianTools")
    end
  end
  commands[buf] = nil
end
local function attach(buf)
  detach(buf)
  if vim.bo[buf].buftype ~= "" or vim.bo[buf].filetype ~= "markdown" or not M.workspace(api.nvim_buf_get_name(buf)) then
    return
  end
  assert(
    not api.nvim_get_commands({}).ObsidianTools and not api.nvim_buf_get_commands(buf, {}).ObsidianTools,
    "ObsidianTools command already exists"
  )
  api.nvim_buf_create_user_command(buf, "ObsidianTools", function(opts)
    safe(M.command, opts.args)
  end, {
    nargs = "*",
    desc = "Vault note workflows",
    complete = function()
      return actions
    end,
    force = false,
  })
  commands[buf] = api.nvim_buf_get_commands(buf, {}).ObsidianTools
end
function M.dispose()
  active = false
  generation = generation + 1
  if group then
    pcall(api.nvim_del_augroup_by_id, group)
    group = nil
  end
  for _, buf in ipairs(vim.tbl_keys(commands)) do
    detach(buf)
  end
  local index = package.loaded["obsidian_tools.index"]
  if index then
    index.dispose()
  end
end
function M.setup(opts)
  local next_config = require("obsidian_tools.config").normalize(opts)
  M.dispose()
  config = next_config
  active = true
  group = api.nvim_create_augroup("ObsidianTools", { clear = true })
  api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
    group = group,
    callback = function(event)
      safe(attach, event.buf)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      commands[event.buf] = nil
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    safe(attach, buf)
  end
  return M
end
return M
