# local-fim

fill-in-the-middle completion for Neovim via a local [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`.

## Requirements

- Neovim >= 0.10
- `llama-server` on `PATH`
- `curl`

## Install (lazy.nvim)

This plugin ships with no built-in profiles — model paths, quant choices, and
sampling tweaks are personal to your machine, not something to hardcode in a
published package. Pick one of the ready-to-copy profiles from
[Profiles](#profiles) below (or write your own) and pass it as `opts.profiles`:

```lua
{
  "tollefj/local-fim.nvim",
  event = "VimEnter",
  opts = {
    endpoint = "http://127.0.0.1:8012",
    profile = "qwen2.5-coder",
    profiles = {
      ["qwen2.5-coder"] = {
        mode = "infill",
        top_p = 0.9,
        stop = { "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>" },
        server = {
          hf = "ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF",
          gguf = "qwen2.5-coder-3b-q8_0.gguf",
          ctx = 8192,
        },
      },
    },
  },
  config = function(_, opts)
    local fim = require("local-fim")
    fim.setup(opts)
    require("local-fim.server").ensure(fim.config)
  end,
}
```

The port is set to 8012 to not conflict with the default 8080 in case of multiple local servers.

## Keymaps

| Command             | Default key | Action                          |
| ------------------- | ----------- | ------------------------------- |
| `:LocalFimComplete` | `<C-g>` (i) | generate            |
| `:LocalFimDismiss`  | `<C-k>` (i) | dismiss | 
| `:LocalFimProfile`  | —           | switch profile and (re)start it |

Configure your own completion mapping. I use tab + ctrl-g.

## Profiles

A profile is a parameter bundle for one model. The plugin itself defines only
the mechanics — `profile_defaults`, `resolve`, `validate` in
[`lua/local-fim/profiles.lua`](lua/local-fim/profiles.lua) — and ships no
concrete models. Pass yours as `opts.profiles` at setup, declaring only what
differs from `profile_defaults`; profiles with a `server` field auto-start
`llama-server` when needed via `:LocalFimProfile` or
`require("local-fim.server").ensure(...)`.

The same set of examples also lives at
[`tests/fim/profiles.lua`](tests/fim/profiles.lua), used by the eval harness:

```lua
opts = {
  profile = "qwen2.5-coder", -- pick your active one
  profiles = {
    -- Qwen2.5-Coder 3B, infill mode (llama-server assembles the prompt from
    -- the GGUF's own FIM metadata).
    ["qwen2.5-coder"] = {
      mode = "infill",
      top_p = 0.9,
      stop = { "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>" },
      server = {
        hf = "ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF",
        gguf = "qwen2.5-coder-3b-q8_0.gguf",
        ctx = 8192,
      },
    },

    -- Qwen3.5-4B, same Qwen FIM tokenizer family (infill mode). Local-only
    -- GGUF (no known hf repo), so `source` is pinned to "local". This
    -- checkpoint's own eos is "<|im_end|>" rather than a FIM-family token, and
    -- it's prone to looping on already-emitted lines under greedy decoding
    -- without DRY sampling to break the cycle — see "Repetition controls"
    -- below for what dry_* does.
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

    -- Mellum-4b-dpo (StarCoder-tokenizer base), SPM FIM via the shared
    -- completion builder (mode = "completion", the default). eos is
    -- <|endoftext|>; the <fim_*>/<filename> entries guard a runaway fill.
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
  },
}
```

## Repetition controls

`temperature = 0` (the `profile_defaults`) means greedy decoding — deterministic,
but with no way to escape a cycle once the model starts repeating a line. A few
optional per-profile fields, sent straight through to llama-server's sampler,
address that without falling back to a flat `repeat_penalty` (which docks
*any* recently-seen token, including legitimate code reuse like variable names
or closing punctuation):

| Field                    | What it does                                                                 |
| ------------------------ | ----------------------------------------------------------------------------- |
| `dry_multiplier`         | DRY sampling strength; `0`/omitted disables it (llama-server default: `0`)     |
| `dry_base`                | DRY penalty growth base (llama-server default: `1.75`)                       |
| `dry_allowed_length`      | longest repeat allowed before DRY kicks in (llama-server default: `2`)       |
| `dry_penalty_last_n`      | how far back DRY looks for repeats (llama-server default: `64`)              |
| `dry_sequence_breakers`   | characters that reset DRY's repeat match (llama-server default: `{"\n", ":", "\"", "*"}`) |
| `repeat_penalty`          | flat penalty on any recently-seen token; blunt, prefer DRY for code           |

DRY only penalizes tokens that would extend an *already-repeated* n-gram past
`dry_allowed_length`, so it targets literal loops (the same line generated
over and over) without touching normal code reuse. One gotcha: the default
`dry_sequence_breakers` include `"` and `:`, which reset the match mid-line for
code like `print("done")` — exactly the kind of line these models loop on — so
a code profile that's still looping with DRY enabled likely needs
`dry_sequence_breakers = { "\n" }` to narrow the reset to line boundaries only.

## FIM tokens

Every profile's `stop` list and (for `mode = "completion"`) `tokens` table
must match the exact marker strings the model was trained on — copied from
its tokenizer, not guessed. Two token families are in use by the example
profiles above:

| Role                | Mellum (`<fim_prefix>` style)        | Qwen (`<\|fim_prefix\|>` style)     |
| ------------------- | ------------------------------------- | ------------------------------------ |
| before the gap      | `<fim_prefix>`                        | `<\|fim_prefix\|>`                   |
| after the gap       | `<fim_suffix>`                        | `<\|fim_suffix\|>`                   |
| generate here       | `<fim_middle>`                        | `<\|fim_middle\|>`                   |
| batch padding       | —                                      | `<\|fim_pad\|>`                      |
| end of generation   | `<\|endoftext\|>` / `<\|im_end\|>`    | `<\|endoftext\|>`                    |

- `mode = "completion"` (Mellum profiles) — this plugin assembles the prompt
  itself using a profile's `tokens` table, so the prefix/suffix/middle
  strings above must be set there exactly.
- `mode = "infill"` (Qwen profiles) — `llama-server`'s `/infill` endpoint
  reads the FIM marker strings out of the GGUF's own metadata and assembles
  the prompt itself; `tokens` is ignored, so only `stop` matters here.

`stop` always needs the model's actual end-of-generation token(s), plus every
FIM/structural marker that could otherwise leak into visible output if the
model degenerates mid-completion:

- `<|fim_pad|>` — a training-time alignment token (pads short examples out to
  a uniform batch length); harmless if it never appears, but stops generation
  immediately if it does.
- `<|file_sep|>` / `<|repo_name|>` (Qwen2.5-Coder-family only) — mark the
  start of a new file or repo block in Qwen's multi-file pretraining format.
  If the model emits one of these mid-completion, it has stopped continuing
  your code and started hallucinating a new file/repo header; treating them
  as stop tokens cuts that off before it gets spliced into your buffer.

When adding a model, pull these strings from its `tokenizer_config.json` /
`special_tokens_map.json` rather than assuming they match an existing
profile's family — see `.claude/skills/integrate-fim-model/SKILL.md`.

## Model source

A profile's `server` names the model in up to three ways:

- `hf` — a HuggingFace repo (`<user>/<model>[:quant]`), loaded with `-hf` (auto-download).
- `gguf` — a filename under `model_dir` (defaults to ~/LLM), loaded with `-m <model_dir>/<gguf>`.
- `model` — a raw `llama-server` arg list; if set, it is used verbatim and wins.

Two top-level options decide which is used:

```lua
opts = {
  source = "local",     -- "local" (default) or "hf"
  model_dir = "~/LLM",  -- where local .gguf files live (~ expanded)
}
```

`source` is only the tie-breaker when a profile provides **both** `hf` and `gguf`;
the default `"local"` means a present local file is used over downloading. If a
profile provides only one of the two, that one is used regardless of `source`
(with a notice when it differs from your request). Override `source` or
`model_dir` per profile by setting them at the profile's top level or inside its
`server` block:

```lua
profiles = {
  ["qwen2.5-coder"] = { source = "hf" },  -- always pull this one from HuggingFace
}
```

Most of the example profiles above ship with both `hf` and `gguf`, so by default
they run from `model_dir` once the files are present, and fall back to
HuggingFace otherwise. `qwen3.5-4b` is local-only (no known `hf` repo for this
GGUF), so it always loads from `model_dir` regardless of `source`.

`model_dir` is a single global directory; if your local `.gguf` files live one
level deeper (e.g. `~/LLM/models/<ModelName>/model.gguf` rather than flat
`~/LLM/model.gguf`), override `server.model_dir` per profile instead of the
global one:

```lua
profiles = {
  ["qwen3.5-4b"] = { server = { model_dir = "~/LLM/models/Qwen3.5-4B-FIM" } },
}
```

A profile pointed at a nonexistent path makes `llama-server` exit immediately
on load — `:checkhealth local-fim` flags this (`local model file not found`),
but `require("local-fim.server").ensure()`'s background auto-start does not
surface the failure, so it can look like the server "just didn't start."

## Context

Beyond the current buffer's prefix/suffix, the plugin feeds the model cross-file
context in the `<filename>`-marked format these FIM models were trained on:

- **LSP definitions** — on each trigger, the definitions of the symbols the
  cursor is typing against are resolved via the language server and their
  enclosing code regions are included. This is the highest-signal context (the
  exact APIs you are calling). Lookups are async with a hard deadline, so a slow
  or missing server never blocks a suggestion.
- **Member-access types** — when you trigger right after a member operator
  (`transport.`, `a?.b`, `p->x`, `T::y`), the *type* of the receiver is resolved
  (`textDocument/typeDefinition`) and its class/interface region is included and
  placed nearest the completion point, so the model sees the members available
  on `transport`.
- **Ring buffer** — recently visited files fill whatever budget remains.

Both share one token budget, with LSP definitions taking priority and placed
nearest the completion point. Defaults:

```lua
opts = {
  max_extra_tokens = 2048,  -- shared budget for all cross-file context (~4 chars/token)
  lsp = {
    enabled = true,
    timeout_ms = 150,   -- deadline before sending without (some) definitions
    max_symbols = 8,    -- candidate symbols resolved per trigger
    max_def_lines = 30, -- per-definition line cap
  },
}
```

Set `lsp = { enabled = false }` to use ring-only context. When no language
server is attached to the buffer, the plugin silently falls back to the ring.

## Health

`:checkhealth local-fim` validates the active profile, and checks that `llama-server` is reachable.

## License

MIT
