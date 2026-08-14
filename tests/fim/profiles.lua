-- Example profiles for exercising the eval harness. The plugin itself ships
-- no built-in profiles (lua/local-fim/profiles.lua) -- these are the same
-- Mellum/Qwen2.5-Coder/Qwen3.5 examples documented in the README, kept here
-- so `tests/fim/run.lua` has something concrete to run against without
-- requiring a personal Neovim config. Copy whichever you need into your own
-- `opts.profiles` (with your own `server.model_dir`/`server.gguf` paths).
return {
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
