# local-fim

Local fill-in-the-middle completion for Neovim, served by a local
[llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`. Ghost-text
suggestions from per-model "profiles" you can swap at runtime.

## Requirements

- Neovim >= 0.10
- `llama-server` on `PATH` ([llama.cpp](https://github.com/ggml-org/llama.cpp))
- `curl`

## Install (lazy.nvim)

```lua
{
  "tollefj/local-fim.nvim",
  event = "VimEnter",
  opts = {
    endpoint = "http://127.0.0.1:8012",
    profile = "qwen2.5-coder",
  },
  config = function(_, opts)
    local fim = require("local-fim")
    fim.setup(opts)
    require("local-fim.server").ensure(fim.config) -- offer to start llama-server if down
  end,
}
```

## Commands and keymaps

| Command             | Default key | Action                          |
| ------------------- | ----------- | ------------------------------- |
| `:LocalFimComplete` | `<C-g>` (i) | Request a suggestion            |
| `:LocalFimDismiss`  | `<C-k>` (i) | Dismiss the current suggestion  |
| `:LocalFimProfile`  | —           | Switch profile and (re)start it |

Accept is left to your completion mapping (e.g. `<Tab>` via `fim.accept()`).

## Profiles

A profile is a parameter bundle for one model. Built-in: `mellum2` (default),
`mellum4b`, `qwen2.5-coder`. Profiles with a `server` field can auto-start
`llama-server`; the active profile's `mode` is `completion` (prompt built
locally) or `infill` (delegated to `/infill`).

Add a model by editing `lua/local-fim/profiles.lua` (declare only what differs from
`profile_defaults`) or pass `opts.profiles` at setup:

```lua
opts = {
  profile = "my-model",
  profiles = {
    ["my-model"] = {
      mode = "infill",
      stop = { "<|endoftext|>" },
      server = { model = { "-hf", "<user>/<repo>" }, ctx = 8192 },
    },
  },
}
```

## Health

`:checkhealth local-fim` reports the resolved profile, validates it, and checks that
`llama-server` is reachable.

## License

MIT
