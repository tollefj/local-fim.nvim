# local-fim.nvim

github copilot-style fill-in-the-middle code completion in Neovim. Inference is done locally through `llama.cpp`. spawns on port 8012 to avoid conflicts with other server instances (e.g., if using llama-swap)

## reqs

- Neovim >= 0.10
- `curl`
- `llama-server` (comes with [llama.cpp](https://github.com/ggml-org/llama.cpp))

## a bit about FIM

regular chat-style completion sees what comes *before* as the context.
Some models are trained for FIM, which means they get shon a prefix, suffix, and tasked to generate the content in-between.

the context is built using nvim to fetch the correct data, including some clever things with the LSP to extract function names and so on from imported things.

on every trigger, the plugin builds context from two sources and merges them:

### file history

the plugin keeps small snapshots of the files you edit, so context from a file you were just in five minutes ago is still around.

### LSP

pulls in the enclosing function/class/etc from wherever, based on where your current cursor is
typing `client.` it also asks the LSP for the *type* of `client`, so the model can see its members.

LSP lookup has a deadline of 150ms by default and is async, so there will always be a completion.

the resulting LSP info is merged next to the prefix/suffix.
closest-and-most-relevant nearest the cursor.
a context window is set to as a limit on the injected data.

## setup

the `hf` link in a profile points to the hugging face repo: it will download the model with llama.cpp-native functions. the gguf points to a local file on your machine under the`~/LLM` dir.

llama-server will spawn upon starting nvim with a y/n/change profile option.

### lazy.nvim

```lua
return {
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

### packer.nvim

```lua
use({
  "tollefj/local-fim.nvim",
  config = function()
    local fim = require("local-fim")
    fim.setup({
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
    })
    require("local-fim.server").ensure(fim.config)
  end,
})
```

### vim-plug

```vim
Plug 'tollefj/local-fim.nvim'
```

then in your config (`init.lua`, or a `lua require(...)`'d file), call setup the same way as above:

```lua
local fim = require("local-fim")
fim.setup({
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
})
require("local-fim.server").ensure(fim.config)
```

## usage

`<C-g>` to generate
`<C-k>` to dismiss
`:LocalFimProfile` lets you swap models/profile

