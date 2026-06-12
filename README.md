# local-fim

Local fill-in-the-middle completion for Neovim via a local [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server`.

## Requirements

- Neovim >= 0.10
- `llama-server` on `PATH`
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
    require("local-fim.server").ensure(fim.config)
  end,
}
```

The port is set to 8012 to not conflict with the default 8080 in case of multiple local servers.

## Keymaps

| Command             | Default key | Action                          |
| ------------------- | ----------- | ------------------------------- |
| `:LocalFimComplete` | `<C-g>` (i) | Request a suggestion            |
| `:LocalFimDismiss`  | `<C-k>` (i) | Dismiss the current suggestion  |
| `:LocalFimProfile`  | —           | Switch profile and (re)start it |

Configure your own completion mapping. I use tab + ctrl-g.

## Profiles

A profile is a parameter bundle for one model.
Profiles with a `server` field auto-start `llama-server` when needed. See [`lua/local-fim/profiles.lua`](lua/local-fim/profiles.lua).
To add a model, pass `opts.profiles` at setup. Declare only what differs from `profile_defaults`:

```lua
-- Qwen2.5-Coder 3B, infill mode (llama-server assembles the prompt)
opts = {
  profile = "qwen2.5-coder",
  profiles = {
    ["qwen2.5-coder"] = {
      mode = "infill",
      top_p = 0.9,
      stop = { "<|endoftext|>", "<|fim_pad|>", "<|file_sep|>", "<|repo_name|>" },
      server = {
        model = { "-hf", "ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF" },
        ctx = 8192,
      },
    },
  },
}
```

## Health

`:checkhealth local-fim` validates the active profile, and checks that `llama-server` is reachable.

## License

MIT
