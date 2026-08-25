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
---@field model_dir string           -- directory holding local .gguf files (~ expanded)
---@field request_timeout_ms integer
---@field max_prefix_lines integer
---@field max_suffix_lines integer
---@field max_extra_tokens integer  -- shared budget for the whole `extra` list (LSP defs + ring)
---@field ring { max_chunks: integer, chunk_lines: integer }
---@field lsp { enabled: boolean, timeout_ms: integer, max_symbols: integer, max_def_lines: integer }
---@field keymaps { trigger: string|false, dismiss: string|false, accept: string|false }
---@field highlight string

-- Editor-side configuration, shared across every profile.
M.defaults = {
  endpoint = "http://127.0.0.1:8012",
  -- No default: this plugin ships no built-in profiles (see profiles.lua), so
  -- you must pass `profile` (a key in your own `opts.profiles`) at setup().
  -- "completion" mode builds the SPM prompt locally; "infill" (a profile's
  -- `mode`) delegates to llama-server's /infill.
  profile = nil,
  -- Directory holding local .gguf files. A profile whose `server.gguf` names a
  -- file already present here loads it locally with `-m`; otherwise (if the
  -- profile also sets `server.hf`) it downloads via HuggingFace instead.
  model_dir = "~/LLM",
  request_timeout_ms = 8000,
  max_prefix_lines = 80,
  max_suffix_lines = 40,
  -- Token budget for cross-file context (LSP definitions + ring chunks),
  -- approximated as ~4 chars/token. Kept small so the bulk of the model's
  -- window stays available for prefix/suffix.
  max_extra_tokens = 2048,
  ring = {
    max_chunks = 16,
    chunk_lines = 40,
  },
  -- Cross-file context pulled from the language server on each trigger: the
  -- definitions of the symbols the cursor is typing against. Disable with
  -- `lsp = { enabled = false }` to fall back to ring-only context.
  lsp = {
    enabled = true,
    timeout_ms = 150, -- deadline before sending the request without (some) defs
    max_symbols = 8, -- candidate positions resolved per trigger
    max_def_lines = 30, -- per-definition line cap
  },
  keymaps = {
    trigger = "<C-g>",
    dismiss = "<C-k>",
    accept = false, -- accept is wired into the cmp <Tab> mapping in lsp.lua
  },
  highlight = "Comment",
}

-- Resolved flat config (defaults + active profile). Placeholder until
-- setup() runs with a real `profile`/`profiles` pair -- there's no built-in
-- profile to merge in here.
---@type local_fim.Config
M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), profiles.resolve(nil))

-- Bumped on every trigger and on dismiss so a late async gather/LSP callback
-- from a superseded request compares stale and drops instead of firing.
M._gen = 0

-- Request a completion for the current cursor position and show it as ghost
-- text. Context gathering is async (LSP definition lookups), so the request is
-- fired from the gather callback once cross-file context is ready.
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

  -- No built-in profiles ship with this plugin (see profiles.lua), so a valid
  -- `profile` must name a key in `opts.profiles`. There's no sensible
  -- fallback to limp along on -- bail out loudly instead of half-initializing
  -- with an empty profile.
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
