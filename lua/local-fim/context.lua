local M = {}

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

local function entry_len(filename, text)
  return #filename + #text + 4
end

-- extra is ordered [ring..., LSP...] so LSP context sits nearest the FIM point.
local function assemble_extra(lsp_entries, current, cfg)
  local budget = (cfg.max_extra_tokens or 2048) * 4
  local used, seen = 0, {}
  local lsp_keep = {}
  for _, e in ipairs(lsp_entries) do
    local len = entry_len(e.filename, e.text)
    if used + len <= budget then
      lsp_keep[#lsp_keep + 1] = e
      used = used + len
      seen[e.filename] = true
    end
  end

  local ring_keep = {}
  for _, chunk in ipairs(M.chunks) do
    if chunk.filename ~= current and not seen[chunk.filename] then
      local len = entry_len(chunk.filename, chunk.text)
      if used + len <= budget then
        ring_keep[#ring_keep + 1] = { filename = chunk.filename, text = chunk.text }
        used = used + len
      end
    end
  end

  local extra = {}
  for _, e in ipairs(ring_keep) do
    extra[#extra + 1] = e
  end
  for _, e in ipairs(lsp_keep) do
    extra[#extra + 1] = e
  end
  return extra
end

function M.gather(cfg, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
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
  require("local-fim.lsp_context").collect(cfg, bufnr, row, col, function(lsp_entries)
    local extra = assemble_extra(lsp_entries, current, cfg)
    callback({ prefix = prefix, suffix = suffix, extra = extra, filename = current })
  end)
end

return M
