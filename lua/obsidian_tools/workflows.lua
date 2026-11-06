local U, N = require("obsidian_tools.util"), require("obsidian_tools.note")
local M = {}
local function quote(value)
  return vim.json.encode(value)
end
local function render(vault, text, ctx)
  local values = {
    title = ctx.title,
    id = ctx.id,
    date = os.date(vault.config.templates.date_format, ctx.time),
    time = os.date(vault.config.templates.time_format, ctx.time),
  }
  for key, value in pairs(vault.config.templates.substitutions) do
    values[key] = type(value) == "function" and value(vim.deepcopy(ctx)) or value
  end
  return (
    text:gsub("{{%s*([%w_-]+)%s*}}", function(key)
      return values[key] ~= nil and tostring(values[key]) or "{{" .. key .. "}}"
    end)
  )
end
function M.templates(vault)
  local root = U.safe(vault.path, vault.path .. "/" .. vault.config.templates.folder)
  local output = {}
  if not vim.uv.fs_stat(root) then
    return output
  end
  local function visit(directory)
    local scan = assert(vim.uv.fs_scandir(directory))
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      local path = directory .. "/" .. name
      if kind == "file" and name:match("%.md$") then
        output[#output + 1] = U.relative(root, path)
      elseif kind == "directory" then
        visit(path)
      end
    end
  end
  visit(root)
  table.sort(output)
  return output
end
function M.template(vault, name, ctx)
  local root = U.safe(vault.path, vault.path .. "/" .. vault.config.templates.folder)
  local path = U.safe(root, root .. "/" .. name)
  return render(vault, U.read(path, vault.config.max_file_bytes).raw, ctx)
end
local function note_text(vault, ctx, template, tags)
  local text
  if template then
    text = M.template(vault, template, ctx)
  end
  if text then
    -- Template IDs are placeholders, not permanent note identities.
    local lines = vim.split(text, "\n", { plain = true })
    if lines[1] == "---" then
      local ending
      for row = 2, #lines do
        if lines[row] == "---" or lines[row] == "..." then
          ending = row
          break
        end
      end
      assert(ending, "Template has unterminated YAML front matter")
      local replaced = false
      for row = 2, ending - 1 do
        if lines[row]:match("^id:") then
          lines[row], replaced = "id: " .. quote(ctx.id), true
        end
      end
      if not replaced then
        table.insert(lines, 2, "id: " .. quote(ctx.id))
      end
      if ctx.extra_aliases then
        local aliases = N.metadata(lines).aliases
        for _, value in ipairs(ctx.extra_aliases) do
          if not vim.tbl_contains(aliases, value) then
            aliases[#aliases + 1] = value
          end
        end
        local first
        for row = 2, #lines do
          if lines[row]:match("^aliases:") then
            first = row
            break
          end
          if lines[row] == "---" or lines[row] == "..." then
            break
          end
        end
        if first then
          lines[first] = "aliases: " .. quote(aliases)
          while lines[first + 1] and lines[first + 1]:match("^%s+%-%s+") do
            table.remove(lines, first + 1)
          end
        else
          table.insert(lines, 2, "aliases: " .. quote(aliases))
        end
      end
      return table.concat(lines, "\n")
    end
  end
  local header = { "---", "id: " .. quote(ctx.id), "aliases: " .. quote(ctx.extra_aliases or { ctx.title }), "tags:" }
  for _, tag in ipairs(tags or {}) do
    header[#header + 1] = "  - " .. quote(tag)
  end
  header[#header + 1] = "---"
  return table.concat(header, "\n") .. "\n\n" .. (text or ("# " .. ctx.title .. "\n"))
end
function M.new(vault, title, template)
  assert(type(title) == "string" and vim.trim(title) ~= "", "A note title is required")
  local ctx = { title = vim.trim(title), time = os.time(), vault = vault.path }
  local stem = vault.config.note_id and vault.config.note_id(ctx.title, vim.deepcopy(ctx))
    or (tostring(ctx.time) .. "-" .. ctx.title:gsub("%s+", "-"):gsub('[/\\:%*%?"<>|#]', ""):lower())
  assert(
    type(stem) == "string" and stem ~= "" and not stem:find("[/\\]") and not stem:find("[\r\n]"),
    "note_id must return a filename stem"
  )
  local root = U.safe(vault.path, vault.path .. "/" .. vault.config.notes_subdir)
  local suffix, path = 1, nil
  repeat
    ctx.id = stem .. (suffix > 1 and "-" .. suffix or "")
    path = U.safe(vault.path, root .. "/" .. ctx.id .. ".md")
    suffix = suffix + 1
  until not vim.uv.fs_lstat(path)
  return U.create(vault.path, path, note_text(vault, ctx, template))
end
function M.daily(vault, date)
  local timestamp = os.time()
  if date and date ~= "" then
    local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    assert(year, "Daily date must be YYYY-MM-DD")
    timestamp = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
    assert(os.date("%Y-%m-%d", timestamp) == date, "Invalid calendar date")
  end
  local id = os.date(vault.config.daily_notes.date_format, timestamp)
  assert(not id:find("[/\\]"), "Daily date format must produce a filename")
  local path = U.safe(vault.path, vault.path .. "/" .. vault.config.daily_notes.folder .. "/" .. id .. ".md")
  if vim.uv.fs_stat(path) then
    return path
  end
  local ctx = {
    title = id,
    id = id,
    time = timestamp,
    vault = vault.path,
    extra_aliases = { id, os.date(vault.config.daily_notes.alias_format, timestamp) },
  }
  return U.create(
    vault.path,
    path,
    note_text(vault, ctx, vault.config.daily_notes.template, vault.config.daily_notes.default_tags)
  )
end
function M.insert_template(vault, name)
  local file = vim.api.nvim_buf_get_name(0)
  U.safe(vault.path, file)
  local note = N.metadata(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  local ctx = {
    title = note.aliases[1] or vim.fs.basename(file):gsub("%.md$", ""),
    id = note.id or vim.fs.basename(file):gsub("%.md$", ""),
    time = os.time(),
    vault = vault.path,
  }
  local text = M.template(vault, name, ctx)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(0, vim.fn.line(".") - 1, vim.fn.line(".") - 1, false, lines)
end
return M
