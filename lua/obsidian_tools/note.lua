local U = require("obsidian_tools.util")
local D = require("markdown_tools.document")
local L = require("markdown_tools.links")
local M = {}
local function scalar(text)
  text = vim.trim(text)
  if text:sub(1, 1) == '"' then
    local ok, value = pcall(vim.json.decode, text)
    if ok and type(value) == "string" then
      return value
    end
  elseif text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return text:sub(2, -2):gsub("''", "'")
  end
  return vim.trim(text:gsub("%s+#.*$", ""))
end
local function list(text)
  text = vim.trim(text)
  if text:sub(1, 1) ~= "[" then
    return text ~= "" and { scalar(text) } or {}
  end
  local values, word, quote, escape = {}, "", nil, false
  for i = 2, #text - 1 do
    local c = text:sub(i, i)
    if escape then
      word, escape = word .. c, false
    elseif c == "\\" and quote == '"' then
      word, escape = word .. c, true
    elseif quote then
      word = word .. c
      if c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote, word = c, word .. c
    elseif c == "," then
      values[#values + 1], word = scalar(word), ""
    else
      word = word .. c
    end
  end
  if vim.trim(word) ~= "" then
    values[#values + 1] = scalar(word)
  end
  return values
end
function M.metadata(lines)
  local data, field = { aliases = {}, tags = {} }, nil
  if lines[1] ~= "---" then
    return data
  end
  for row = 2, #lines do
    local line = lines[row]
    if line == "---" or line == "..." then
      break
    end
    local key, value = line:match("^([%w_-]+):%s*(.*)$")
    if key then
      field = key
      if key == "aliases" or key == "tags" then
        data[key] = list(value)
      elseif key == "id" or key == "title" then
        data[key] = scalar(value)
      end
    elseif field == "aliases" or field == "tags" then
      local entry = line:match("^%s+%-%s+(.+)$")
      if entry then
        data[field][#data[field] + 1] = scalar(entry)
      end
    end
  end
  return data
end
function M.parse(vault, path, doc)
  doc = doc or U.document(path)
  local data, scan = M.metadata(doc.lines), D.scan(doc.lines)
  local stem = vim.fs.basename(path):gsub("%.md$", "")
  local tags = {}
  for _, tag in ipairs(data.tags) do
    tags[tag:gsub("^#", "")] = true
  end
  for row, line in ipairs(doc.lines) do
    if not scan.excluded[row] then
      local masked = L.mask(line)
      for offset, tag in masked:gmatch("()#([%w_/%-%z\128-\255]+)") do
        local prev = offset > 1 and masked:sub(offset - 1, offset - 1) or ""
        if (prev == "" or prev:match("%s")) and tag:match("[^%d/]") then
          tags[tag] = true
        end
      end
    end
  end
  local note = {
    path = path,
    relative = U.relative(vault.path, path),
    stem = stem,
    id = data.id or stem,
    title = data.title or data.aliases[1] or (scan.headings[1] and scan.headings[1].title) or stem,
    aliases = data.aliases,
    tags = vim.tbl_keys(tags),
    headings = scan.headings,
    links = L.parse(doc.lines),
    doc = doc,
    blocks = {},
  }
  for row, line in ipairs(doc.lines) do
    if not scan.excluded[row] then
      local id = L.mask(line):match("%s%^([%w-]+)%s*$")
      if id then
        note.blocks[id] = row
      end
    end
  end
  table.sort(note.tags)
  return note
end
return M
