local M = {}
local D, L = require("markdown_tools.document"), require("markdown_tools.links")
local function context(ctx)
  if ctx.mode ~= "insert" or ctx.filetype ~= "markdown" or not vim.api.nvim_buf_is_valid(ctx.bufnr) then
    return
  end
  local file = vim.api.nvim_buf_get_name(ctx.bufnr)
  local vault = require("obsidian_tools").workspace(file)
  if not vault then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
  if D.scan(lines).excluded[ctx.row + 1] then
    return
  end
  local before = L.mask(ctx.before)
  local start, query = before:match("()%[%[([^%[%]]*)$")
  if start then
    return { vault = vault, file = file, kind = "link", start_col = start + 1, query = query }
  end
  start, query = before:match("()#([%w_/%-]*)$")
  if start and (start == 1 or before:sub(start - 1, start - 1):match("%s")) then
    return { vault = vault, file = file, kind = "tag", start_col = start, query = query }
  end
end
function M.new()
  return {
    trigger = function(ctx)
      return context(ctx) ~= nil
    end,
    complete = function(ctx, callback)
      local request = context(ctx)
      if not request then
        callback({ items = {} })
        return
      end
      local cancelled = false
      local cancel = require("obsidian_tools.index").refresh(request.vault, function(index)
        if cancelled then
          return
        end
        local items, start_col = {}, request.start_col
        local ending = ctx.col
        local suffix = ctx.line:sub(ctx.col + 1)
        local closing = request.kind == "link" and suffix:match("^[^%[%]]*%]%]")
        if closing then
          ending = ending + #closing
        end
        local function add(label, text, detail, filter)
          if text:find("[\r\n]") then
            return
          end
          items[#items + 1] = {
            label = label,
            kind = request.kind == "tag" and 14 or 18,
            detail = detail,
            filterText = filter or label,
            textEdit = {
              range = {
                start = { line = ctx.row, character = start_col },
                ["end"] = { line = ctx.row, character = ending },
              },
              newText = text,
            },
            data = { vault = request.vault.path },
          }
        end
        if request.kind == "tag" then
          local tags = {}
          for _, note in ipairs(index.notes) do
            for _, tag in ipairs(note.tags) do
              tags[tag] = true
            end
          end
          for _, tag in ipairs(vim.tbl_keys(tags)) do
            add(tag, tag, "Vault tag")
          end
        else
          local base, anchor = request.query:match("^(.-)#(.*)$")
          if base then
            local candidates = require("obsidian_tools.resolve").candidates(
              request.vault,
              index,
              { target = base, wiki = true },
              request.file
            )
            for _, candidate in ipairs(candidates or {}) do
              local note = candidate.note
              if note then
                if anchor:sub(1, 1) == "^" then
                  for id in pairs(note.blocks) do
                    add("^" .. id, base .. "#^" .. id .. "]]", note.relative, request.query .. " " .. id)
                  end
                else
                  for _, heading in ipairs(note.headings) do
                    add(
                      heading.title,
                      base .. "#" .. heading.title .. "]]",
                      note.relative,
                      base .. "#" .. heading.title
                    )
                  end
                end
              end
            end
          else
            for _, note in ipairs(index.notes) do
              local target = require("obsidian_tools.resolve").target(request.vault, note.path, request.file, true)
              local title = note.title:gsub("[|%[%]]", "")
              add(
                note.title,
                target .. "|" .. title .. "]]",
                note.relative,
                note.title .. " " .. note.id .. " " .. note.relative .. " " .. table.concat(note.aliases, " ")
              )
            end
          end
        end
        callback({ items = items, start_col = start_col, reusable = false })
      end)
      return function()
        cancelled = true
        cancel()
      end
    end,
  }
end
return M
