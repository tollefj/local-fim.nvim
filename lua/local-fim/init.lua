local context = require("local-fim.context")
local client = require("local-fim.client")
local ui = require("local-fim.ui")
local profiles = require("local-fim.profiles")

local M = {}

-- Available profiles (built-in + any added via opts.profiles). Edit models in
-- lua/local-fim/profiles.lua; setup() refreshes this from there plus opts.profiles.
---@type table<string, local_fim.Profile>
M.profiles = vim.deepcopy(profiles.profiles)

---@class local_fim.Config: local_fim.Profile
---@field endpoint string            -- llama-server base URL
---@field profile string             -- active profile name
---@field source "hf"|"local"        -- where to load the model from when a profile offers both
---@field model_dir string           -- directory holding local .gguf files (~ expanded)
---@field request_timeout_ms integer
---@field max_prefix_lines integer
---@field max_suffix_lines integer
---@field ring { max_chunks: integer, chunk_lines: integer }
---@field keymaps { trigger: string|false, dismiss: string|false, accept: string|false }
---@field highlight string

-- Editor-side configuration, shared across every profile.
M.defaults = {
  endpoint = "http://127.0.0.1:8012",
  -- Active profile from M.profiles. "completion" mode builds the SPM prompt
  -- locally; "infill" (a profile's `mode`) delegates to llama-server's /infill.
  profile = "mellum2",
  -- Model source for profiles that declare both `hf` and `gguf`. "local" loads
  -- `model_dir/<gguf>` with `-m` (preferred: use the local file if present);
  -- "hf" pulls from HuggingFace (auto-download). Set per-profile (top-level or
  -- inside `server`) to override. When a profile offers only one of the two,
  -- that one is used regardless of `source`.
  source = "local",
  model_dir = "~/LLM",
  request_timeout_ms = 8000,
  max_prefix_lines = 80,
  max_suffix_lines = 40,
  ring = {
    max_chunks = 16,
    chunk_lines = 40,
  },
  keymaps = {
    trigger = "<C-g>",
    dismiss = "<C-k>",
    accept = false, -- accept is wired into the cmp <Tab> mapping in lsp.lua
  },
  highlight = "Comment",
}

-- Resolved flat config (defaults + active profile). Populated by setup().
---@type local_fim.Config
M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), profiles.resolve(M.profiles[M.defaults.profile]))

-- Request a completion for the current cursor position and show it as ghost text.
function M.complete()
  local ctx = context.gather(M.config)
  client.infill(ctx, M.config, function(content, _err)
    if content and content ~= "" then
      ui.show(content)
    end
  end)
end

function M.has_suggestion()
  return ui.has_suggestion()
end

function M.accept()
  return ui.accept()
end

function M.dismiss()
  client.cancel()
  ui.clear()
end

-- Pick a profile from M.profiles and switch to it live, then (re)launch its
-- server. Re-runs setup with the original opts so editor-side settings (e.g.
-- endpoint) survive; only `profile` changes. Used by the startup prompt's
-- "(C)hange profile" branch and the :LocalFimProfile command.
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
    server.stop() -- free the port if we launched a server for the old profile
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

  -- Feed the ring buffer from other files as you move through them.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
    group = grp,
    callback = function(ev)
      context.capture(ev.buf, M.config)
    end,
  })

  -- A move or edit away from the anchor invalidates a shown suggestion.
  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = grp,
    callback = function()
      if not ui.has_suggestion() then
        ui.clear()
      end
    end,
  })

  -- Leaving insert mode always dismisses it: the anchor no longer applies, and
  -- on InsertLeave the cursor hasn't shifted yet, so has_suggestion() can still
  -- report true. Also cancels any in-flight request.
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = grp,
    callback = M.dismiss,
  })
end

function M.setup(opts)
  opts = opts or {}
  M._opts = vim.deepcopy(opts)

  -- Let users add or override profiles, then pick the active one. Persist the
  -- merged set so choose_profile() can list user-added profiles too.
  local available = vim.tbl_deep_extend("force", vim.deepcopy(profiles.profiles), opts.profiles or {})
  M.profiles = available

  local name = opts.profile or M.defaults.profile
  if not available[name] then
    vim.notify(
      ("local-fim: unknown profile %q; falling back to %q"):format(tostring(name), M.defaults.profile),
      vim.log.levels.ERROR
    )
    name = M.defaults.profile
  end

  -- Resolve (profile_defaults < profile) and validate; fall back on a bad one.
  local active = profiles.resolve(available[name])
  local ok, err = profiles.validate(active)
  if not ok then
    vim.notify(
      ("local-fim: profile %q invalid: %s; falling back to %q"):format(name, err, M.defaults.profile),
      vim.log.levels.ERROR
    )
    name = M.defaults.profile
    active = profiles.resolve(available[name])
  end

  -- Precedence: global defaults < active profile < user opts. `profile` and
  -- `profiles` are selectors, not config fields, so strip them before flattening.
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
