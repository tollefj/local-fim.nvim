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
-- Identify the model in one to three ways; presence gates availability and the
-- resolved `source` is the tie-breaker only when both `hf` and `gguf` are set.
---@field hf? string         -- HuggingFace repo, "<user>/<model>[:quant]"; loaded with `-hf`
---@field gguf? string       -- filename under `model_dir`; loaded with `-m model_dir/<gguf>`
---@field model? string[]    -- raw llama-server args; if set, used verbatim and wins over hf/gguf
---@field source? "hf"|"local"  -- override the global source for this profile
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

---@type table<string, local_fim.Profile>
M.profiles = {
  -- Mellum-4b-dpo (StarCoder-tokenizer base), SPM FIM via the shared completion
  -- builder. eos is <|endoftext|>; the <fim_*>/<filename> entries guard a runaway fill.
  -- hf-only: demonstrates the `-hf` load path (no local gguf).
  mellum4b = {
    stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>", "<|endoftext|>" },
    server = {
      hf = "JetBrains/Mellum-4b-dpo-all-gguf:Q8_0",
      ctx = 8192,
    },
  },
  -- Mellum2 ...-Instruct, raw FIM (its tokenizer keeps the <fim_*> tokens).
  -- Its eos is <|im_end|>; <|endoftext|> is kept as a second guard.
  -- hf-only: demonstrates the `-hf` load path (no local gguf).
  mellum2 = {
    stop = { "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>", "<|im_end|>", "<|endoftext|>" },
    server = {
      hf = "JetBrains/Mellum2-12B-A2.5B-Instruct-GGUF-Q6_K:Q6_K",
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
      hf = "ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF",
      gguf = "qwen2.5-coder-3b-q8_0.gguf",
      source = "local",
      ctx = 8192,
    },
  },
  -- Qwen3.5-4B, same Qwen FIM tokenizer family as qwen2.5-coder (fim_prefix/
  -- middle/suffix/pad kept as real tokens, PSM order) so it uses the same
  -- "infill" delegation. Local-only GGUF: no known hf repo, so `gguf` is the
  -- only source and `source` is pinned to "local" regardless of the global
  -- default. ctx assumed at 8192 to match the other profiles.
  --
  -- This checkpoint's own eos is "<|im_end|>" (per llama-server /props), not
  -- one of the FIM-family guard tokens below -- without it in `stop`, and
  -- with greedy decoding (temperature 0) giving it no way to escape a cycle,
  -- it was looping on already-emitted lines until n_predict cut it off (see
  -- tests/fim/pipeline.py, tests/fim/totals.py). DRY targets exactly that: it
  -- only penalizes tokens that would extend an already-repeated n-gram, so it
  -- breaks the loop without docking normal code reuse the way a flat
  -- repeat_penalty would.
  ["qwen3.5-4b"] = {
    mode = "infill",
    top_p = 0.9,
    stop = { "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>", "<|im_end|>" },
    dry_multiplier = 0.8,
    dry_allowed_length = 1,
    dry_penalty_last_n = 256,
    dry_sequence_breakers = { "\n" },
    server = {
      gguf = "Qwen3.5-4B-Q6_K.gguf",
      source = "local",
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
  if p.source ~= nil and p.source ~= "hf" and p.source ~= "local" then
    return false, 'source must be "hf" or "local"'
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
    if s.hf == nil and s.gguf == nil and s.model == nil then
      return false, "server must define at least one of hf, gguf, or model"
    end
    if s.hf ~= nil and type(s.hf) ~= "string" then
      return false, "server.hf must be a string"
    end
    if s.gguf ~= nil and type(s.gguf) ~= "string" then
      return false, "server.gguf must be a string"
    end
    if s.model ~= nil and (not list_of_strings(s.model) or #s.model == 0) then
      return false, "server.model must be a non-empty list of strings"
    end
    if s.source ~= nil and s.source ~= "hf" and s.source ~= "local" then
      return false, 'server.source must be "hf" or "local"'
    end
    if type(s.ctx) ~= "number" then
      return false, "server.ctx must be a number"
    end
  end
  return true
end

return M
