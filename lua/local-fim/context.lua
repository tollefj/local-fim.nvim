local M = {}

-- Ring buffer of context chunks gathered from other buffers. Each entry is
-- { filename = <relative path>, text = <joined lines> }. Most-recently-seen
-- chunks live at the front; the list is capped at config.ring.max_chunks.
M.chunks = {}

local function relpath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "[scratch]"
  end
  return vim.fn.fnamemodify(name, ":.")
end

local function is_real_buffer(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  return vim.api.nvim_buf_get_name(bufnr) ~= ""
end

-- Capture an up-to-chunk_lines slice of `bufnr` and push it to the front of
-- the ring, evicting any previous chunk for the same file and trimming to cap.
function M.capture(bufnr, cfg)
  if not is_real_buffer(bufnr) then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local take = math.min(total, cfg.ring.chunk_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, take, false)
  local text = table.concat(lines, "\n")
  if text:match("^%s*$") then
    return
  end

  local filename = relpath(bufnr)
  for i, chunk in ipairs(M.chunks) do
    if chunk.filename == filename then
      table.remove(M.chunks, i)
      break
    end
  end
  table.insert(M.chunks, 1, { filename = filename, text = text })
  while #M.chunks > cfg.ring.max_chunks do
    table.remove(M.chunks)
  end
end

-- Build the FIM context for the current cursor position:
--   prefix : text before the cursor (current line + up to max_prefix_lines above)
--   suffix : text after the cursor  (current line + up to max_suffix_lines below)
--   extra  : ring-buffer chunks from other files (current file excluded)
function M.gather(cfg)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0)) -- row is 1-based
  row = row - 1

  local prefix_start = math.max(0, row - cfg.max_prefix_lines)
  local prefix_lines = vim.api.nvim_buf_get_lines(bufnr, prefix_start, row, false)
  local cur = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  table.insert(prefix_lines, cur:sub(1, col))
  local prefix = table.concat(prefix_lines, "\n")

  local total = vim.api.nvim_buf_line_count(bufnr)
  local suffix_end = math.min(total, row + 1 + cfg.max_suffix_lines)
  local after_lines = vim.api.nvim_buf_get_lines(bufnr, row + 1, suffix_end, false)
  local suffix = cur:sub(col + 1)
  if #after_lines > 0 then
    suffix = suffix .. "\n" .. table.concat(after_lines, "\n")
  end

  local current = relpath(bufnr)
  local extra = {}
  for _, chunk in ipairs(M.chunks) do
    if chunk.filename ~= current then
      table.insert(extra, { filename = chunk.filename, text = chunk.text })
    end
  end

  return { prefix = prefix, suffix = suffix, extra = extra, filename = current }
end

return M
