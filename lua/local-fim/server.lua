local M = {}

-- Handle for a llama-server WE started. Stays nil when the server was already
-- running (yours or a prior session), so stop() never kills a server we didn't
-- launch.
M.job = nil

local function join_path(dir, file)
  local d = vim.fn.expand(dir)
  d = d:gsub("/$", "")
  return d .. "/" .. file
end

-- Resolve the model-identity args for `llama-server` from a profile's `server`
-- spec. Precedence: a raw `model` array wins; otherwise pick between `hf` and
-- `gguf` by the resolved `source` (server-level override, then global). When
-- only one of hf/gguf exists it is used regardless of `source`. Pure: returns
-- the argv plus an optional note string (caller decides how to surface it) so
-- callers other than launch (e.g. health) can reuse it without side effects.
--   { "-hf", "<repo>" }  |  { "-m", "<model_dir>/<gguf>" }  |  <model verbatim>
---@param cfg local_fim.Config
---@return string[]? args, string? note_or_err  -- note when args set, err when nil
function M.model_args(cfg)
  local s = cfg.server
  if not s then
    return nil, "profile has no server spec"
  end
  if s.model then
    return s.model
  end
  local source = s.source or cfg.source or "hf"
  local dir = s.model_dir or cfg.model_dir or "~/LLM"
  if s.hf and s.gguf then
    if source == "local" then
      return { "-m", join_path(dir, s.gguf) }
    end
    return { "-hf", s.hf }
  elseif s.gguf then
    local note = source == "hf"
      and ("profile %q has no hf repo; using local gguf"):format(cfg.profile)
      or nil
    return { "-m", join_path(dir, s.gguf) }, note
  elseif s.hf then
    local note = source == "local"
      and ("profile %q has no local gguf; using hf repo"):format(cfg.profile)
      or nil
    return { "-hf", s.hf }, note
  end
  return nil, "server must define at least one of hf, gguf, or model"
end

-- Build the launch command from the active profile's `server` spec, injecting
-- the port from `endpoint` so it stays the single source of truth. Returns a
-- list-form command (argv) ready for vim.system.
--   llama-server <model...> --port <port> -c <ctx> --context-shift
local function build_cmd(cfg)
  local port = cfg.endpoint:match(":(%d+)")
  if not port then
    return nil, "could not parse port from endpoint: " .. tostring(cfg.endpoint)
  end
  local margs, note = M.model_args(cfg)
  if not margs then
    return nil, note
  end
  if note then
    vim.notify("local-fim: " .. note, vim.log.levels.WARN)
  end
  local cmd = { "llama-server" }
  vim.list_extend(cmd, margs)
  -- context.lua budgets cross-file `extra` context by a ~4-chars/token
  -- estimate, not an exact token count, so a request's assembled prompt
  -- (prefix + suffix + extra) can occasionally exceed `ctx`. --context-shift
  -- (off by default) makes llama-server discard the oldest context and keep
  -- going in that case instead of erroring or silently truncating mid-token.
  vim.list_extend(cmd, { "--port", port, "-c", tostring(cfg.server.ctx), "--context-shift" })
  return cmd
end

local function is_running(cfg, cb)
  vim.system(
    { "curl", "-s", "--max-time", "1", cfg.endpoint .. "/health" },
    { text = true },
    vim.schedule_wrap(function(res)
      cb(res.code == 0 and res.stdout ~= nil and res.stdout ~= "")
    end)
  )
end

-- Launch llama-server for the active profile in the background. No-op (with a
-- warning) when the profile has no `server` spec, so choose_profile() can call
-- it for any selection without first checking.
function M.start(cfg)
  if not cfg.server then
    vim.notify(
      ("local-fim: profile %q has no server config to start"):format(cfg.profile),
      vim.log.levels.WARN
    )
    return
  end

  local cmd, err = build_cmd(cfg)
  if not cmd then
    vim.notify("local-fim: " .. err, vim.log.levels.ERROR)
    return
  end

  M.job = vim.system(cmd, { text = false }, function()
    M.job = nil
  end)
  vim.notify("local-fim: starting llama-server\n" .. table.concat(cmd, " "), vim.log.levels.INFO)

  -- Tear the server down when nvim exits, but only this one.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("local-fim_server", { clear = true }),
    once = true,
    callback = M.stop,
  })
end

function M.stop()
  if M.job then
    pcall(function()
      M.job:kill(15) -- SIGTERM
    end)
    M.job = nil
  end
end

-- If the active profile defines a `server` and the endpoint is down, offer to
-- start it in the background. No-op when auto-start isn't configured, curl is
-- missing, or the server is already up.
function M.ensure(cfg)
  if not cfg.server then
    return
  end
  if vim.fn.executable("curl") == 0 then
    return
  end

  is_running(cfg, function(up)
    if up then
      return
    end
    local choice = vim.fn.confirm(
      ("local-fim: llama-server not running at %s.\nStart %s in the background?"):format(cfg.endpoint, cfg.profile),
      "&Yes\n&No\n&Change profile",
      1
    )
    if choice == 1 then
      M.start(cfg)
    elseif choice == 3 then
      require("local-fim").choose_profile()
    end
  end)
end

return M
