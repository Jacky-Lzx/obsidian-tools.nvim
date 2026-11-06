local M = {}
local uv = vim.uv
function M.path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p")):gsub("/$", "")
end
function M.inside(root, path)
  return path == root or vim.startswith(path, root .. "/")
end
function M.safe(root, path)
  root, path = M.path(root), M.path(path)
  assert(M.inside(root, path), "Path escapes vault: " .. path)
  local ancestor = path
  while not uv.fs_lstat(ancestor) and ancestor ~= vim.fs.dirname(ancestor) do
    ancestor = vim.fs.dirname(ancestor)
  end
  local real_root, real_ancestor = uv.fs_realpath(root), uv.fs_realpath(ancestor)
  assert(real_root and real_ancestor and M.inside(real_root, real_ancestor), "Symlink escapes vault: " .. path)
  return path
end
function M.relative(root, path)
  return path:sub(#root + 2)
end
function M.relpath(base, path)
  local left, right = vim.split(M.path(base), "/", { plain = true }), vim.split(M.path(path), "/", { plain = true })
  local index = 1
  while left[index] and left[index] == right[index] do
    index = index + 1
  end
  local result = {}
  for _ = index, #left do
    result[#result + 1] = ".."
  end
  for i = index, #right do
    result[#result + 1] = right[i]
  end
  return table.concat(result, "/")
end
function M.read(path, limit)
  local stat, err = uv.fs_stat(path)
  assert(stat and stat.type == "file", err or ("Not a file: " .. path))
  assert(stat.size <= (limit or 4 * 1024 * 1024), "Note exceeds size limit: " .. path)
  local fd = assert(uv.fs_open(path, "r", 0))
  local raw, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  assert(raw, read_err)
  local lines, offsets, start = {}, {}, 1
  repeat
    local ending = raw:find("\n", start, true)
    offsets[#offsets + 1] = start - 1
    lines[#lines + 1] = raw:sub(start, ending and ending - 1 or #raw):gsub("\r$", "")
    start = ending and ending + 1 or #raw + 2
  until start > #raw
  return { path = path, raw = raw, lines = lines, offsets = offsets, stat = stat }
end
function M.loaded(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then
      return buf
    end
  end
end
function M.document(path, limit)
  local doc = M.read(path, limit)
  local buf = M.loaded(path)
  if buf and vim.bo[buf].modified then
    doc.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    doc.dirty, doc.buf = true, buf
  end
  return doc
end
function M.patch(doc, edits)
  table.sort(edits, function(a, b)
    return a.first > b.first
  end)
  local raw, boundary = doc.raw, #doc.raw + 1
  for _, edit in ipairs(edits) do
    assert(edit.last < boundary, "Overlapping edits")
    raw = raw:sub(1, edit.first - 1) .. edit.text .. raw:sub(edit.last + 1)
    boundary = edit.first
  end
  return raw
end
function M.stage(path, raw)
  local name, fd
  for _ = 1, 10 do
    name = path .. ".obsidian-tools-" .. tostring(uv.hrtime())
    fd = uv.fs_open(name, "wx", 384)
    if fd then
      break
    end
  end
  assert(fd, "Cannot stage file: " .. path)
  local ok, err = pcall(function()
    local offset = 0
    while offset < #raw do
      offset = offset + assert(uv.fs_write(fd, raw:sub(offset + 1), offset))
    end
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(name)
    error(err)
  end
  return name
end
function M.create(root, path, raw)
  path = M.safe(root, path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  M.safe(root, path)
  local fd, err = uv.fs_open(path, "wx", 420)
  assert(fd, err)
  local ok, failure = pcall(function()
    local offset = 0
    while offset < #raw do
      offset = offset + assert(uv.fs_write(fd, raw:sub(offset + 1), offset))
    end
    assert(uv.fs_fsync(fd))
  end)
  uv.fs_close(fd)
  if not ok then
    uv.fs_unlink(path)
    error(failure)
  end
  return path
end
function M.open(path, row, col)
  vim.cmd.edit(vim.fn.fnameescape(path))
  if row then
    vim.api.nvim_win_set_cursor(0, { row, col or 0 })
    vim.cmd("normal! zv")
  end
end
return M
