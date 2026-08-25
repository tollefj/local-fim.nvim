-- Per-model parameter bundles. One llama-server runs on `endpoint`; you swap
-- the loaded model locally and point `profile` at the matching bundle so the
-- stop set (notably the eos guard) tracks the model you're actually serving.
--
-- This plugin ships with no built-in profiles: model paths, quant choices,
-- and sampling tweaks are personal to your machine, not something a published
-- package should hardcode. Define yours in your own Neovim config via
-- `opts.profiles` at setup() -- see the README's "Profiles" section for
-- ready-to-copy examples (Mellum and Qwen2.5-Coder/Qwen3.5 families). Declare
-- only what differs from `profile_defaults` below; everything you omit is
-- inherited.

local M = {}

---@class local_fim.Tokens
---@field filename string  -- marker prepended to each context file's name
---@field prefix string    -- FIM prefix token
---@field suffix string    -- FIM suffix token
---@field middle string    -- FIM middle token

---@class local_fim.ServerSpec
-- Identify the model with `hf`, `gguf`, or both. When both are set, the local
-- file wins if it's present on disk; otherwise it downloads via `hf`.
---@field hf? string         -- HuggingFace repo, "<user>/<model>[:quant]"; loaded with `-hf`
---@field gguf? string       -- filename under `model_dir`; loaded with `-m model_dir/<gguf>`
---@field model_dir? string     -- override the global model_dir for this profile
---@field ctx integer        -- context size, passed as `-c`

---@class local_fim.Profile
---@field mode "completion"|"infill"  -- "completion": build the SPM prompt locally; "infill": delegate to /infill
---@field n_predict integer
---@field temperature number
---@field top_k integer
---@field top_p number
---@field t_max_predict_ms integer
---@field stop string[]               -- strings that halt generation
---@field tokens? local_fim.Tokens          -- required for "completion" mode; ignored for "infill"
---@field server? local_fim.ServerSpec      -- omit to disable auto-start for this profile
-- Repetition controls, all optional -- omitted fields are left out of the
-- request body entirely so llama-server's own defaults apply. DRY (dry_*) is
-- the preferred fix for a model that loops on literal repeated lines: unlike
-- repeat_penalty it only penalizes tokens that would extend an
-- already-repeated n-gram, so it doesn't dock legitimate code reuse (variable
-- names, closing punctuation, etc).
---@field repeat_penalty? number      -- flat penalty on any recently-seen token; blunt, can hurt code reuse
---@field dry_multiplier? number      -- DRY strength; 0 or omitted disables it (llama-server default: 0)
---@field dry_base? number            -- DRY penalty growth base (llama-server default: 1.75)
---@field dry_allowed_length? integer -- longest repeat allowed before DRY kicks in (llama-server default: 2)
---@field dry_penalty_last_n? integer -- how far back DRY looks for repeats (llama-server default: 64)
---@field dry_sequence_breakers? string[] -- chars that reset DRY's repeat match (llama-server default:
                                          -- {"\n", ":", "\"", "*"} -- the quote/colon defaults reset the
                                          -- match mid-line for code like `print("done")`, which is exactly
                                          -- the kind of line these models loop on, so code profiles should
                                          -- narrow this to just newline

-- Shared baseline. A profile is merged over this, so it only declares deltas.
---@type local_fim.Profile
M.profile_defaults = {
  mode = "completion",
  n_predict = 128,
  temperature = 0,
  top_k = 40,
  top_p = 0.99,
  t_max_predict_ms = 1000,
  tokens = {
    filename = "<filename>",
    prefix = "<fim_prefix>",
    suffix = "<fim_suffix>",
    middle = "<fim_middle>",
  },
}

-- No bundled models -- add yours via `opts.profiles` in your Neovim config.
-- See the README for the Mellum/Qwen2.5-Coder/Qwen3.5 examples that used to
-- live here.
---@type table<string, local_fim.Profile>
M.profiles = {}

-- Merge `profile_defaults` under a single profile table.
---@param profile local_fim.Profile
---@return local_fim.Profile
function M.resolve(profile)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.profile_defaults), vim.deepcopy(profile or {}))
end

local function list_of_strings(t)
  if type(t) ~= "table" then
    return false
  end
  for _, v in ipairs(t) do
    if type(v) ~= "string" then
      return false
    end
  end
  return true
end

-- Validate a resolved profile. Returns true, or false plus a message naming
-- the offending field.
---@param p local_fim.Profile
---@return boolean ok, string? err
function M.validate(p)
  if type(p) ~= "table" then
    return false, "profile is not a table"
  end
  if p.mode ~= "completion" and p.mode ~= "infill" then
    return false, ('mode must be "completion" or "infill" (got %s)'):format(vim.inspect(p.mode))
  end
  if type(p.n_predict) ~= "number" or p.n_predict <= 0 then
    return false, "n_predict must be a positive number"
  end
  if not list_of_strings(p.stop) then
    return false, "stop must be a list of strings"
  end
  if p.mode == "completion" then
    if type(p.tokens) ~= "table" then
      return false, "completion mode requires a tokens table"
    end
    for _, k in ipairs({ "prefix", "suffix", "middle", "filename" }) do
      if type(p.tokens[k]) ~= "string" then
        return false, ("tokens.%s must be a string"):format(k)
      end
    end
  end
  for _, k in ipairs({ "repeat_penalty", "dry_multiplier", "dry_base", "dry_allowed_length", "dry_penalty_last_n" }) do
    if p[k] ~= nil and type(p[k]) ~= "number" then
      return false, (k .. " must be a number")
    end
  end
  if p.dry_sequence_breakers ~= nil and not list_of_strings(p.dry_sequence_breakers) then
    return false, "dry_sequence_breakers must be a list of strings"
  end
  if p.server ~= nil then
    local s = p.server
    if type(s) ~= "table" then
      return false, "server must be a table"
    end
    if s.hf == nil and s.gguf == nil then
      return false, "server must define hf and/or gguf"
    end
    if s.hf ~= nil and type(s.hf) ~= "string" then
      return false, "server.hf must be a string"
    end
    if s.gguf ~= nil and type(s.gguf) ~= "string" then
      return false, "server.gguf must be a string"
    end
    if type(s.ctx) ~= "number" then
      return false, "server.ctx must be a number"
    end
  end
  return true
end

return M
