local M = {}

M.job = nil
local notified_down = false

local OPTIONAL_SAMPLING_KEYS = {
  "repeat_penalty",
  "dry_multiplier",
  "dry_base",
  "dry_allowed_length",
  "dry_penalty_last_n",
  "dry_sequence_breakers",
}

local function sampling(cfg)
  local body = {
    n_predict = cfg.n_predict,
    temperature = cfg.temperature,
    top_k = cfg.top_k,
    top_p = cfg.top_p,
    stop = cfg.stop,
    cache_prompt = true,
    t_max_predict_ms = cfg.t_max_predict_ms,
    stream = false,
  }
  for _, k in ipairs(OPTIONAL_SAMPLING_KEYS) do
    if cfg[k] ~= nil then
      body[k] = cfg[k]
    end
  end
  return body
end

local function infill_request(ctx, cfg)
  local body = sampling(cfg)
  body.input_prefix = ctx.prefix
  body.input_suffix = ctx.suffix
  body.prompt = ""
  if ctx.extra and #ctx.extra > 0 then
    body.input_extra = ctx.extra
  end
  return "/infill", body
end

local function completion_request(ctx, cfg)
  local t = cfg.tokens
  local parts = {}
  for _, e in ipairs(ctx.extra or {}) do
    parts[#parts + 1] = t.filename .. e.filename .. "\n" .. e.text .. "\n\n"
  end
  parts[#parts + 1] = t.filename .. (ctx.filename or "") .. "\n"
  parts[#parts + 1] = t.suffix .. ctx.suffix
  parts[#parts + 1] = t.prefix .. ctx.prefix
  parts[#parts + 1] = t.middle

  local body = sampling(cfg)
  body.prompt = table.concat(parts)
  return "/completion", body
end

function M.cancel()
  if M.job then
    pcall(function()
      M.job:kill(15)
    end)
    M.job = nil
  end
end

function M.infill(ctx, cfg, on_done)
  M.cancel()

  local path, body
  if cfg.mode == "infill" then
    path, body = infill_request(ctx, cfg)
  else
    path, body = completion_request(ctx, cfg)
  end

  local cmd = {
    "curl",
    "-s",
    "--max-time",
    tostring(cfg.request_timeout_ms / 1000),
    "-X",
    "POST",
    cfg.endpoint .. path,
    "-H",
    "Content-Type: application/json",
    "-d",
    vim.json.encode(body),
  }

  M.job = vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    M.job = nil
    if res.code ~= 0 or res.stdout == nil or res.stdout == "" then
      if not notified_down then
        notified_down = true
        vim.notify(
          ("local-fim: no response from %s (is llama-server running?)"):format(cfg.endpoint),
          vim.log.levels.WARN
        )
      end
      return on_done(nil, "request failed")
    end
    notified_down = false

    local ok, decoded = pcall(vim.json.decode, res.stdout)
    if not ok or type(decoded) ~= "table" then
      return on_done(nil, "invalid json")
    end
    if decoded.error then
      local msg = type(decoded.error) == "table" and decoded.error.message or tostring(decoded.error)
      vim.notify("local-fim: server error: " .. msg, vim.log.levels.ERROR)
      return on_done(nil, msg)
    end

    on_done(decoded.content or "", nil, { request = body, response = decoded })
  end))
end

return M
