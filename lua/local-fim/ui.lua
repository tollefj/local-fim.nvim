local M = {}

local ns = vim.api.nvim_create_namespace("local-fim")

M.current = nil

local highlight = "Comment"

function M.setup(cfg)
  highlight = cfg.highlight or "Comment"
end

function M.clear()
  if M.current then
    vim.api.nvim_buf_del_extmark(M.current.bufnr, ns, M.current.extmark)
    M.current = nil
  end
end

function M.show(text)
  M.clear()
  if not text or text == "" then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local lines = vim.split(text, "\n", { plain = true })
  local virt_lines = {}
  for i = 2, #lines do
    virt_lines[i - 1] = { { lines[i], highlight } }
  end

  local opts = {
    virt_text = { { lines[1], highlight } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  }
  if #virt_lines > 0 then
    opts.virt_lines = virt_lines
  end

  local extmark = vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, opts)
  M.current = { bufnr = bufnr, row = row, col = col, text = text, extmark = extmark }
end

function M.has_suggestion()
  if not M.current then
    return false
  end
  if vim.api.nvim_get_current_buf() ~= M.current.bufnr then
    return false
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return (row - 1) == M.current.row and col == M.current.col
end

function M.accept()
  if not M.has_suggestion() then
    return false
  end
  local text = M.current.text
  M.clear()
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_put(lines, "c", false, true)
  return true
end

return M
