local U, N = require("obsidian_tools.util"), require("obsidian_tools.note")
local M = {}
local states, generation = {}, 0
local function scanner(vault, cache)
  cache = cache or {}
  local seen = {}
  local ignored = {}
  for _, name in ipairs(vault.config.ignore) do
    ignored[name] = true
  end
  local directories, iterator, directory, result = { vault.path }, nil, nil, { notes = {}, by_path = {}, errors = {} }
  local function step(limit)
    for _ = 1, limit do
      if not iterator then
        directory = table.remove(directories)
        if not directory then
          table.sort(result.notes, function(a, b)
            return a.relative < b.relative
          end)
          for path in pairs(cache) do
            if not seen[path] then
              cache[path] = nil
            end
          end
          return result
        end
        local err
        iterator, err = vim.uv.fs_scandir(directory)
        if not iterator then
          result.errors[#result.errors + 1] = directory .. ": " .. tostring(err)
        end
      end
      if iterator then
        local name, kind = vim.uv.fs_scandir_next(iterator)
        if not name then
          iterator = nil
        elseif not ignored[name] then
          local path = directory .. "/" .. name
          if kind == "directory" and U.relative(vault.path, path) ~= vault.config.templates.folder then
            directories[#directories + 1] = path
          elseif kind == "file" and name:match("%.md$") then
            local ok, note = pcall(function()
              seen[path] = true
              local stat = assert(vim.uv.fs_stat(path))
              local buf = U.loaded(path)
              local tick = buf and vim.api.nvim_buf_get_changedtick(buf) or -1
              local key = table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec, tick }, ":")
              local previous = cache[path]
              if previous and previous.key == key then
                return previous.note
              end
              local doc = U.document(path, vault.config.max_file_bytes)
              assert(#doc.raw <= vault.config.max_file_bytes, "Note exceeds configured size limit")
              local note = N.parse(vault, path, doc)
              cache[path] = { key = key, note = note }
              return note
            end)
            if ok then
              result.notes[#result.notes + 1], result.by_path[path] = note, note
            else
              result.errors[#result.errors + 1] = path .. ": " .. tostring(note)
            end
          end
        end
      end
    end
  end
  return step
end
function M.scan(vault)
  local step, result = scanner(vault), nil
  repeat
    result = step(100)
  until result
  return result
end
function M.refresh(vault, callback)
  local key, token = vault.path, generation
  local state = states[key]
  if not state then
    state = { callbacks = {}, cache = {} }
    states[key] = state
  end
  local subscriber = { callback = callback, active = true }
  state.callbacks[#state.callbacks + 1] = subscriber
  if not state.running then
    state.running = true
    local step = scanner(vault, state.cache)
    local function run()
      if token ~= generation then
        return
      end
      local result = step(40)
      if not result then
        vim.schedule(run)
        return
      end
      state.running, state.snapshot = false, result
      local callbacks = state.callbacks
      state.callbacks = {}
      for _, item in ipairs(callbacks) do
        if item.active then
          item.callback(result)
        end
      end
    end
    vim.schedule(run)
  end
  return function()
    subscriber.active = false
  end
end
function M.dispose()
  generation = generation + 1
  states = {}
end
return M
