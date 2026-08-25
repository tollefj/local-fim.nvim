local M = {}

function M.check()
  local cfg = require("local-fim").config
  vim.health.start("local-fim")
  vim.health.info("profile: " .. tostring(cfg.profile))
  vim.health.info(("mode=%s n_predict=%s top_k=%s top_p=%s"):format(cfg.mode, cfg.n_predict, cfg.top_k, cfg.top_p))
  if cfg.server then
    local margs, err = require("local-fim.server").model_args(cfg)
    if margs then
      vim.health.info("server: llama-server " .. table.concat(margs, " ") .. " -c " .. tostring(cfg.server.ctx))
      if margs[1] == "-m" and vim.fn.filereadable(margs[2]) == 0 then
        vim.health.warn("local model file not found: " .. margs[2])
      end
    else
      vim.health.error("server: " .. tostring(err))
    end
  else
    vim.health.info("server: auto-start disabled (no `server` in profile)")
  end

  local ok, err = require("local-fim.profiles").validate(cfg)
  if ok then
    vim.health.ok("profile valid")
  else
    vim.health.error("invalid profile: " .. err)
  end

  if cfg.lsp and cfg.lsp.enabled then
    local n = #vim.lsp.get_clients({ bufnr = 0 })
    vim.health.info(
      ("lsp context: enabled (%d client(s) on current buffer), budget=%d tokens"):format(n, cfg.max_extra_tokens)
    )
  else
    vim.health.info("lsp context: disabled")
  end

  if vim.fn.executable("curl") == 0 then
    vim.health.error("curl not found on PATH")
    return
  end
  vim.health.ok("curl found")

  local res = vim.system(
    { "curl", "-s", "--max-time", "3", cfg.endpoint .. "/health" },
    { text = true }
  ):wait()

  if res.code ~= 0 or res.stdout == "" then
    vim.health.error("no llama-server at " .. cfg.endpoint, {
      "Start it, e.g.: llama-server -m <mellum-4b-dpo>.gguf --port 8012",
    })
    return
  end
  vim.health.ok("llama-server reachable at " .. cfg.endpoint)

  local props = vim.system(
    { "curl", "-s", "--max-time", "3", cfg.endpoint .. "/props" },
    { text = true }
  ):wait()
  local ok, decoded = pcall(vim.json.decode, props.stdout or "")
  if ok and type(decoded) == "table" then
    local model = (decoded.default_generation_settings or {}).model or decoded.model_path
    if model then
      vim.health.info("model: " .. tostring(model))
    end
  end
end

return M
