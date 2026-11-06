local U, R = require("obsidian_tools.util"), require("obsidian_tools.resolve")
local M = {}
local function clean(path)
  local buf = U.loaded(path)
  assert(not buf or not vim.bo[buf].modified, "Save modified note before renaming: " .. path)
end
function M.plan(vault, source, destination)
  source = U.safe(vault.path, source)
  clean(source)
  assert(source:match("%.md$"), "Only Markdown notes can be renamed")
  assert(type(destination) == "string" and destination ~= "", "A destination is required")
  if not destination:match("%.md$") then
    destination = destination .. ".md"
  end
  local target = U.safe(vault.path, vault.path .. "/" .. destination)
  assert(target ~= source, "Source and destination are identical")
  assert(not vim.uv.fs_lstat(target), "Destination already exists: " .. target)
  assert(not U.loaded(target), "Destination already has an open buffer")
  local snapshot = require("obsidian_tools.index").scan(vault)
  assert(#snapshot.errors == 0, "Cannot rename with unreadable notes: " .. table.concat(snapshot.errors, "\n"))
  assert(snapshot.by_path[source], "Source is not an indexed vault note")
  local plan = { vault = vault.path, source = source, target = target, files = {}, references = 0 }
  for _, note in ipairs(snapshot.notes) do
    local doc, edits, seen = note.doc, {}, {}
    for _, link in ipairs(note.links) do
      local candidates = R.candidates(vault, snapshot, link, note.path)
      if candidates then
        local involves_source = note.path == source
        for _, candidate in ipairs(candidates) do
          if candidate.path == source then
            involves_source = true
          end
        end
        assert(
          not involves_source or #candidates <= 1,
          "Ambiguous link prevents rename: " .. note.relative .. ":" .. link.row
        )
        if #candidates == 1 then
          local candidate = candidates[1]
          local moving = note.path == source and vim.fs.dirname(source) ~= vim.fs.dirname(target)
          if candidate.path == source or moving then
            local name, anchor = R.parts(link)
            -- Pure in-document anchors remain in-document when a note moves.
            if name ~= "" then
              local new_path = candidate.path == source and target or candidate.path
              local new_source = note.path == source and target or note.path
              local replacement = R.target(vault, new_path, new_source, link.wiki)
              if anchor then
                replacement = replacement .. "#" .. (link.target:match("#(.*)$") or anchor)
              end
              clean(note.path)
              local first = doc.offsets[link.target_row] + link.target_first
              local last = doc.offsets[link.target_row] + link.target_last
              local key = first .. ":" .. last
              if not seen[key] and doc.raw:sub(first, last) ~= replacement then
                seen[key] = true
                edits[#edits + 1] = { first = first, last = last, text = replacement }
                plan.references = plan.references + 1
              end
            end
          end
        end
      end
    end
    if #edits > 0 or note.path == source then
      clean(note.path)
      plan.files[#plan.files + 1] = {
        path = note.path,
        target = note.path == source and target or note.path,
        before = doc.raw,
        after = U.patch(doc, edits),
        mode = doc.stat.mode,
      }
    end
  end
  table.sort(plan.files, function(a, b)
    return a.path < b.path
  end)
  return plan
end

function M.apply(plan)
  local staged, backups, changed = {}, {}, {}
  local reserved = false
  local function validate()
    assert(not vim.uv.fs_lstat(plan.target), "Destination appeared after planning")
    assert(not U.loaded(plan.target), "Destination buffer appeared after planning")
    for _, file in ipairs(plan.files) do
      U.safe(plan.vault, file.path)
      U.safe(plan.vault, file.target)
      clean(file.path)
      assert(U.read(file.path).raw == file.before, "Note changed after planning: " .. file.path)
    end
  end
  validate()
  local ok, err = xpcall(function()
    vim.fn.mkdir(vim.fs.dirname(plan.target), "p")
    for _, file in ipairs(plan.files) do
      U.safe(plan.vault, file.target)
      staged[file.path] = U.stage(file.target, file.after)
      backups[file.path] = U.stage(file.path, file.before)
      assert(vim.uv.fs_chmod(staged[file.path], file.mode))
      assert(vim.uv.fs_chmod(backups[file.path], file.mode))
    end
    validate()
    -- Reserve the new destination with exclusive creation; a concurrent creator wins safely.
    local reserve, failure = vim.uv.fs_open(plan.target, "wx", 420)
    assert(reserve, failure)
    vim.uv.fs_close(reserve)
    reserved = true
    for _, file in ipairs(plan.files) do
      assert(vim.uv.fs_rename(staged[file.path], file.target))
      staged[file.path] = nil
      changed[#changed + 1] = file
    end
    assert(vim.uv.fs_unlink(plan.source))
  end, debug.traceback)
  if not ok then
    local failures = {}
    for i = #changed, 1, -1 do
      local file = changed[i]
      local restored, why = vim.uv.fs_rename(backups[file.path], file.path)
      if restored then
        backups[file.path] = nil
      else
        failures[#failures + 1] = tostring(why)
      end
    end
    if reserved then
      vim.uv.fs_unlink(plan.target)
    end
    for _, path in pairs(staged) do
      vim.uv.fs_unlink(path)
    end
    if #failures == 0 then
      for _, path in pairs(backups) do
        vim.uv.fs_unlink(path)
      end
    end
    error(
      err
        .. (
          #failures > 0
            and ("\nRollback failed; backups retained: " .. vim.inspect(backups) .. "\n" .. table.concat(failures, "\n"))
          or ""
        )
    )
  end
  for _, path in pairs(backups) do
    vim.uv.fs_unlink(path)
  end
  for _, file in ipairs(plan.files) do
    local buf = U.loaded(file.path)
    if buf then
      if file.path ~= file.target then
        vim.api.nvim_buf_set_name(buf, file.target)
      end
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("checktime")
      end)
    end
  end
  return { path = plan.target, files = #plan.files, references = plan.references }
end
return M
