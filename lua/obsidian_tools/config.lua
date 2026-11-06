local U = require("obsidian_tools.util")
local M = {}
local defaults = {
  workspaces = {},
  notes_subdir = "notes",
  auto_detect = false,
  daily_notes = {
    folder = "dailies",
    date_format = "%Y-%m-%d",
    alias_format = "%B %-d, %Y",
    template = false,
    default_tags = { "daily-notes" },
  },
  templates = { folder = "templates", date_format = "%Y-%m-%d", time_format = "%H:%M", substitutions = {} },
  note_id = false,
  max_file_bytes = 4 * 1024 * 1024,
  ignore = { ".git", ".obsidian", ".trash", "node_modules" },
}
function M.normalize(opts)
  assert(opts == nil or type(opts) == "table", "setup expects a table")
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(type(config.workspaces) == "table" and vim.islist(config.workspaces), "workspaces must be a list")
  assert(type(config.auto_detect) == "boolean", "auto_detect must be boolean")
  assert(type(config.max_file_bytes) == "number" and config.max_file_bytes > 0, "max_file_bytes must be positive")
  assert(config.note_id == false or type(config.note_id) == "function", "note_id must be a function or false")
  for _, workspace in ipairs(config.workspaces) do
    assert(type(workspace) == "table" and type(workspace.path) == "string", "workspace needs a path")
    workspace.path = U.path(workspace.path)
    workspace.name = workspace.name or vim.fs.basename(workspace.path)
  end
  for _, folder in ipairs({ config.notes_subdir, config.daily_notes.folder, config.templates.folder }) do
    assert(
      type(folder) == "string"
        and folder ~= ""
        and not folder:match("^/")
        and not folder:match("^%.%.$")
        and not folder:match("%.%./"),
      "folders must be vault-relative"
    )
  end
  assert(
    config.daily_notes.template == false or type(config.daily_notes.template) == "string",
    "daily template must be a string or false"
  )
  for _, format in ipairs({
    config.daily_notes.date_format,
    config.templates.date_format,
    config.templates.time_format,
  }) do
    assert(type(format) == "string", "date/time formats must be strings")
  end
  assert(type(config.templates.substitutions) == "table", "substitutions must be a table")
  assert(type(config.ignore) == "table" and vim.islist(config.ignore), "ignore must be a list")
  for _, values in ipairs({ config.ignore, config.daily_notes.default_tags }) do
    assert(type(values) == "table" and vim.islist(values), "ignore/default_tags must be lists")
    for _, value in ipairs(values) do
      assert(type(value) == "string", "ignore/default_tags entries must be strings")
    end
  end
  return config
end
function M.workspace(config, file)
  file = U.path(file or vim.api.nvim_buf_get_name(0))
  local found
  for _, vault in ipairs(config.workspaces) do
    if U.inside(vault.path, file) and (not found or #vault.path > #found.path) then
      found = vault
    end
  end
  if not found and config.auto_detect then
    local marker = vim.fs.find(".obsidian", { path = vim.fs.dirname(file), upward = true, type = "directory" })[1]
    if marker then
      found = { name = vim.fs.basename(vim.fs.dirname(marker)), path = vim.fs.dirname(marker) }
    end
  end
  if found then
    local result = vim.deepcopy(found)
    result.config = config
    return result
  end
end
return M
