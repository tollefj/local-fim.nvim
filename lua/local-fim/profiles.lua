-- Per-model parameter bundles. One llama-server runs on `endpoint`; you swap
-- the loaded model locally and point `profile` at the matching bundle so the
-- stop set (notably the eos guard) tracks the model you're actually serving.
--
-- To add a model: copy an entry below and change only what differs from
-- `profile_defaults`. Everything you omit is inherited.

local M = {}

---@class local_fim.Tokens
---@field filename string  -- marker prepended to each context file's name
---@field prefix string    -- FIM prefix token
---@field suffix string    -- FIM suffix token
---@field middle string    -- FIM middle token

---@class local_fim.ServerSpec
---@field model string[]   -- llama-server args identifying the model, e.g. { "-hf", "<repo>" }
---@field ctx integer      -- context size, passed as `-c`

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

---@type table<string, local_fim.Profile>
M.profiles = {
  -- Mellum-4b-dpo (StarCoder-tokenizer base), SPM FIM via the shared completion
  -- builder. eos is <|endoftext|>; the <fim_*>/<filename> entries guard a runaway fill
  mellum4b = {
    stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>", "<|endoftext|>" },
    server = {
      model = { "-hf", "JetBrains/Mellum-4b-dpo-all-gguf:Q8_0" },
      ctx = 8192,
    },
  },
  -- Mellum2 ...-Instruct, raw FIM (its tokenizer keeps the <fim_*> tokens).
  -- Its eos is <|im_end|>; <|endoftext|> is kept as a second guard.
  mellum2 = {
    stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>", "<|im_end|>", "<|endoftext|>" },
    server = {
      model = { "-hf", "JetBrains/Mellum2-12B-A2.5B-Instruct-GGUF-Q6_K:Q6_K" },
      ctx = 8192,
    },
  },
  -- Qwen2.5-Coder (base) via "infill" so llama-server assembles Qwen's PSM
  -- template from the GGUF's own FIM metadata (the shared completion prompt
  -- builds SPM order, which Qwen was not trained on). infill ignores `tokens`;
  -- the stop set is a defensive guard over the model's eog tokens.
  ["qwen2.5-coder"] = {
    mode = "infill",
    top_p = 0.9,
    stop = { "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>" },
    -- FIM-ready base GGUF published for llama.vim. Swap the size suffix
    -- (1.5B/3B/7B) to trade latency for quality.
    server = {
      model = { "-hf", "ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF" },
      ctx = 8192,
    },
  },
}

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
  if p.server ~= nil then
    if type(p.server) ~= "table" then
      return false, "server must be a table"
    end
    if not list_of_strings(p.server.model) or #p.server.model == 0 then
      return false, "server.model must be a non-empty list of strings"
    end
    if type(p.server.ctx) ~= "number" then
      return false, "server.ctx must be a number"
    end
  end
  return true
end

return M
