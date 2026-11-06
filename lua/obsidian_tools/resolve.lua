local U = require("obsidian_tools.util")
local L = require("markdown_tools.links")
local M = {}
function M.parts(link)
  local target = link.target:gsub("\\([%p])", "%1")
  if target:match("^%a[%w+.-]*:") then
    return
  end
  local name, anchor = target:match("^([^#]*)#(.*)$")
  return L.decode(name or target), anchor and L.decode(anchor)
end
function M.candidates(vault, index, link, source)
  local name, anchor = M.parts(link)
  if name == nil then
    return
  end
  if name == "" then
    return { { path = source, note = index.by_path[source], anchor = anchor } }
  end
  local candidates, found = {}, {}
  local function add(path)
    path = U.path(path)
    if found[path] or not U.inside(vault.path, path) then
      return
    end
    local note, stat = index.by_path[path], vim.uv.fs_stat(path)
    if note or (stat and stat.type == "file" and not path:match("%.md$")) then
      local ok = pcall(U.safe, vault.path, path)
      if ok then
        candidates[#candidates + 1], found[path] = { path = path, note = note, anchor = anchor }, true
      end
    end
  end
  local bases = link.wiki and { vault.path, vim.fs.dirname(source) } or { vim.fs.dirname(source), vault.path }
  if name:sub(1, 1) == "/" then
    bases, name = { vault.path }, name:gsub("^/+", "")
  end
  for _, base in ipairs(bases) do
    local path = base .. "/" .. name
    add(path)
    if not name:match("%.md$") then
      add(path .. ".md")
    end
    if #candidates > 0 then
      return candidates
    end
  end
  if link.wiki and not name:find("/", 1, true) then
    local value = name:gsub("%.md$", "")
    for _, note in ipairs(index.notes) do
      if note.id == value or note.stem == value then
        add(note.path)
      end
    end
    if #candidates == 0 then
      for _, note in ipairs(index.notes) do
        for _, alias in ipairs(note.aliases) do
          if alias == value then
            add(note.path)
            break
          end
        end
      end
    end
  end
  return candidates
end
function M.location(candidate)
  if not candidate.anchor or candidate.anchor == "" then
    return 1, 0
  end
  local note = candidate.note
  if not note then
    return nil, "Cannot resolve an anchor in an attachment"
  end
  local block = candidate.anchor:match("^%^(.*)$")
  if block then
    if note.blocks[block] then
      return note.blocks[block], 0
    end
  else
    for _, heading in ipairs(note.headings) do
      if heading.title == candidate.anchor or heading.slug == candidate.anchor then
        return heading.row, 0
      end
    end
  end
  return nil, "Anchor not found: " .. candidate.anchor
end
function M.target(vault, path, source, wiki)
  if wiki then
    return U.relative(vault.path, path):gsub("%.md$", "")
  end
  local relative = U.relpath(vim.fs.dirname(source), path)
  return (relative:gsub("[%s#%%()%[%]<>]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end
return M
