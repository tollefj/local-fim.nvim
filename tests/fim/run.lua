-- FIM eval harness. For each case X (tests/fim/X.py containing a single <FIM>
-- marker at the completion point), request a completion from the running
-- llama-server twice -- once with no cross-file context, once with X_deps.py
-- injected as `extra` -- and write both to tests/fim/X.output.txt so you can
-- eyeball whether the dependency changed what the model generated.
--
-- This injects X_deps.py directly as cross-file context (the same `extra`
-- channel the LSP path fills), so it tests the model's use of the dependency
-- without needing a live language server. It reuses the plugin's real request
-- builders, so the bytes sent match what the editor sends.
--
-- Requires a llama-server already running at the profile's endpoint.
--
-- Usage (from the repo root):
--   nvim --headless -l tests/fim/run.lua            # all cases
--   nvim --headless -l tests/fim/run.lua greet      # one case
--   LOCAL_FIM_PROFILE=qwen2.5-coder nvim --headless -l tests/fim/run.lua

local src = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(src, ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.runtimepath:append(root)

local fim = require("local-fim")
fim.setup({ profile = vim.env.LOCAL_FIM_PROFILE or fim.defaults.profile })
local cfg = fim.config
local client = require("local-fim.client")

local function read_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  return table.concat(vim.fn.readfile(path), "\n")
end

-- Split a file's contents at the <FIM> marker into prefix/suffix.
local function split_marker(content)
  local s, e = content:find("<FIM>", 1, true)
  if not s then
    error("no <FIM> marker found")
  end
  return content:sub(1, s - 1), content:sub(e + 1)
end

-- Fire one request and block until it returns. Returns the completion string
-- and the request/response meta (the latter carries the actual prompt).
local function complete_sync(ctx)
  local result, meta, done = nil, nil, false
  client.infill(ctx, cfg, function(content, err, m)
    result = content or ("[error] " .. tostring(err))
    meta = m
    done = true
  end)
  vim.wait(cfg.request_timeout_ms + 2000, function()
    return done
  end, 50)
  if not done then
    return "[error] timed out", nil
  end
  return result, meta
end

-- The literal prompt the model received. In completion mode we build it
-- (`request.prompt`); in infill mode llama-server assembles it and echoes it
-- back as `response.prompt`. If the server doesn't echo it, fall back to a
-- readable dump of the structured inputs we sent.
local function prompt_text(meta)
  if not meta then
    return "[unavailable]"
  end
  if meta.response and meta.response.prompt then
    return meta.response.prompt
  end
  if meta.request and meta.request.prompt and meta.request.prompt ~= "" then
    return meta.request.prompt
  end
  local r = meta.request or {}
  local parts = {}
  for _, e in ipairs(r.input_extra or {}) do
    parts[#parts + 1] = "[input_extra: " .. (e.filename or "?") .. "]\n" .. (e.text or "")
  end
  parts[#parts + 1] = "[input_prefix]\n" .. (r.input_prefix or "")
  parts[#parts + 1] = "[input_suffix]\n" .. (r.input_suffix or "")
  return table.concat(parts, "\n")
end

-- Collect dependency context for a case: a single X_deps.py file, and/or every
-- .py under an X_deps/ directory (a multi-file dependency graph). Returns the
-- list of { filename, text } extra entries plus a short label. Glob order is
-- stable, so the entries land in a deterministic order in the prompt.
local function dep_entries(name)
  local entries = {}
  local single = read_file(here .. "/" .. name .. "_deps.py")
  if single then
    entries[#entries + 1] = { filename = name .. "_deps.py", text = single }
  end
  local dir = here .. "/" .. name .. "_deps"
  if vim.fn.isdirectory(dir) == 1 then
    for _, path in ipairs(vim.fn.glob(dir .. "/**/*.py", false, true)) do
      local text = read_file(path)
      if text and not text:match("^%s*$") then
        entries[#entries + 1] = { filename = path:sub(#here + 2), text = text }
      end
    end
  end
  local label = ("%d dep file(s)"):format(#entries)
  if #entries == 1 then
    label = entries[1].filename
  end
  return entries, label
end

local function run_case(name)
  local code = read_file(here .. "/" .. name .. ".py")
  if not code then
    print("skip " .. name .. ": no " .. name .. ".py")
    return
  end
  local prefix, suffix = split_marker(code)

  local deps, dep_label = dep_entries(name)

  local base = {
    prefix = prefix,
    suffix = suffix,
    filename = name .. ".py",
    extra = {},
  }
  local with_dep = vim.deepcopy(base)
  with_dep.extra = deps

  local without, without_meta = complete_sync(base)
  local withdep, withdep_meta = "[skipped] no deps", nil
  if #deps > 0 then
    withdep, withdep_meta = complete_sync(with_dep)
  end

  local out = {
    ("# case: %s   profile: %s   mode: %s   endpoint: %s"):format(name, cfg.profile, cfg.mode, cfg.endpoint),
    ("# deps: %s"):format(dep_label),
    "",
    "=== prompt without deps ===",
    prompt_text(without_meta),
    "",
    ("=== prompt with %s ==="):format(dep_label),
    prompt_text(withdep_meta),
    "",
    "=== completion without deps ===",
    without,
    "",
    ("=== completion with %s ==="):format(dep_label),
    withdep,
  }
  local out_path = here .. "/" .. name .. ".output.txt"
  vim.fn.writefile(vim.split(table.concat(out, "\n"), "\n"), out_path)
  print("wrote " .. out_path)
end

-- Collect case names: CLI args, or every X.py that isn't an X_deps.py.
local cases = {}
if arg and #arg > 0 then
  cases = arg
else
  for _, path in ipairs(vim.fn.glob(here .. "/*.py", false, true)) do
    local stem = vim.fn.fnamemodify(path, ":t:r")
    if not stem:match("_deps$") then
      cases[#cases + 1] = stem
    end
  end
  table.sort(cases)
end

for _, name in ipairs(cases) do
  run_case(name)
end
