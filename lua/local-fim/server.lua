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
-- spec: a local `gguf` is preferred when the file already exists on disk
-- (fastest, no network); otherwise falls back to downloading via `hf`. When
-- only `gguf` is set (no `hf` fallback), its path is returned regardless, so
-- health.lua can surface a "file not found" warning. Pure: no side effects, so
-- callers other than launch (e.g. health) can reuse it.
--   { "-m", "<model_dir>/<gguf>" }  |  { "-hf", "<repo>" }
---@param cfg local_fim.Config
---@return string[]? args, string? err
function M.model_args(cfg)
  local s = cfg.server
  if not s then
    return nil, "profile has no server spec"
  end
  if not s.hf and not s.gguf then
    return nil, "server must define hf and/or gguf"
  end
  if s.gguf then
    local path = join_path(s.model_dir or cfg.model_dir or "~/LLM", s.gguf)
    if not s.hf or vim.fn.filereadable(path) == 1 then
      return { "-m", path }
    end
  end
  return { "-hf", s.hf }
end

-- Build the launch command from the active profile's `server` spec, injecting
-- the port from `endpoint` so it stays the single source of truth. Returns a
-- list-form command (argv) ready for vim.system.
--   llama-server <model...> --port <port> -c <ctx> 
local function build_cmd(cfg)
  local port = cfg.endpoint:match(":(%d+)")
  if not port then
    return nil, "could not parse port from endpoint: " .. tostring(cfg.endpoint)
  end
  local margs, err = M.model_args(cfg)
  if not margs then
    return nil, err
  end
  local cmd = { "llama-server" }
  vim.list_extend(cmd, margs)
  vim.list_extend(cmd, { "--port", port, "-c", tostring(cfg.server.ctx)})
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
