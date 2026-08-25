local context = require("local-fim.context")
local client = require("local-fim.client")
local ui = require("local-fim.ui")
local profiles = require("local-fim.profiles")

local M = {}

---@type table<string, local_fim.Profile>
M.profiles = vim.deepcopy(profiles.profiles)

---@class local_fim.Config: local_fim.Profile
---@field endpoint string
---@field profile string
---@field model_dir string
---@field request_timeout_ms integer
---@field max_prefix_lines integer
---@field max_suffix_lines integer
---@field max_extra_tokens integer
---@field ring { max_chunks: integer, chunk_lines: integer }
---@field lsp { enabled: boolean, timeout_ms: integer, max_symbols: integer, max_def_lines: integer }
---@field keymaps { trigger: string|false, dismiss: string|false, accept: string|false }
---@field highlight string

M.defaults = {
  endpoint = "http://127.0.0.1:8012",
  profile = nil,
  model_dir = "~/LLM",
  request_timeout_ms = 8000,
  max_prefix_lines = 80,
  max_suffix_lines = 40,
  max_extra_tokens = 2048,
  ring = {
    max_chunks = 16,
    chunk_lines = 40,
  },
  lsp = {
    enabled = true,
    timeout_ms = 150,
    max_symbols = 8,
    max_def_lines = 30,
  },
  keymaps = {
    trigger = "<C-g>",
    dismiss = "<C-k>",
    accept = false,
  },
  highlight = "Comment",
}

---@type local_fim.Config
M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), profiles.resolve(nil))

M._gen = 0

function M.complete()
  M._gen = M._gen + 1
  local gen = M._gen
  context.gather(M.config, function(ctx)
    if gen ~= M._gen then
      return
    end
    client.infill(ctx, M.config, function(content, _err)
      if content and content ~= "" then
        ui.show(content)
      end
    end)
  end)
end

function M.has_suggestion()
  return ui.has_suggestion()
end

function M.accept()
  return ui.accept()
end

function M.dismiss()
  M._gen = M._gen + 1 -- invalidate any in-flight gather/request
  client.cancel()
  ui.clear()
end

function M.choose_profile()
  local names = vim.tbl_keys(M.profiles)
  table.sort(names)
  vim.ui.select(names, {
    prompt = ("local-fim: switch profile (current: %s)"):format(M.config.profile),
  }, function(choice)
    if not choice then
      return
    end
    local server = require("local-fim.server")
    server.stop()
    M.setup(vim.tbl_extend("force", M._opts or {}, { profile = choice }))
    server.start(M.config)
  end)
end

local function set_keymaps(km)
  if km.trigger then
    vim.keymap.set("i", km.trigger, M.complete, { desc = "local-fim: request completion" })
  end
  if km.dismiss then
    vim.keymap.set("i", km.dismiss, M.dismiss, { desc = "local-fim: dismiss suggestion" })
  end
  if km.accept then
    vim.keymap.set("i", km.accept, function()
      if not M.accept() then
        return km.accept
      end
    end, { expr = true, desc = "local-fim: accept suggestion" })
  end
end

local function set_autocmds()
  local grp = vim.api.nvim_create_augroup("local-fim", { clear = true })

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
    group = grp,
    callback = function(ev)
      context.capture(ev.buf, M.config)
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = grp,
    callback = function()
      if not ui.has_suggestion() then
        ui.clear()
      end
    end,
  })

  -- InsertLeave fires before the cursor moves, so has_suggestion() can still
  -- read true here; dismiss unconditionally instead of checking it.
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = grp,
    callback = M.dismiss,
  })
end

function M.setup(opts)
  opts = opts or {}
  M._opts = vim.deepcopy(opts)

  local available = vim.tbl_deep_extend("force", vim.deepcopy(profiles.profiles), opts.profiles or {})
  M.profiles = available

  local name = opts.profile
  if name == nil or not available[name] then
    vim.notify(
      ("local-fim: unknown profile %q; set `profile` + `profiles` in setup() (see README)"):format(tostring(name)),
      vim.log.levels.ERROR
    )
    return
  end

  local active = profiles.resolve(available[name])
  local ok, err = profiles.validate(active)
  if not ok then
    vim.notify(("local-fim: profile %q invalid: %s"):format(name, err), vim.log.levels.ERROR)
    return
  end

  local user = vim.deepcopy(opts)
  user.profile, user.profiles = nil, nil
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), active, user)
  M.config.profile = name

  ui.setup(M.config)
  set_keymaps(M.config.keymaps)
  set_autocmds()

  vim.api.nvim_create_user_command("LocalFimComplete", M.complete, { desc = "local-fim: request completion" })
  vim.api.nvim_create_user_command("LocalFimDismiss", M.dismiss, { desc = "local-fim: dismiss suggestion" })
  vim.api.nvim_create_user_command("LocalFimProfile", M.choose_profile, { desc = "local-fim: switch profile" })
end

return M
