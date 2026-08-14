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
-- Each completion is also run through a handful of automated sanity checks
-- (leaked FIM tokens, hitting n_predict with no natural stop, degenerate
-- repeated lines, verbatim echo of the suffix) -- see `find_issues` below.
-- These catch failure modes that are easy to miss by eyeballing a completion
-- in isolation (e.g. a completion that "looks like code" but is the model
-- looping on a line already present after the cursor). Issues are written
-- inline in the .output.txt and summarized to stdout at the end of the run.
--
-- Requires a llama-server already running at the profile's endpoint. Profiles
-- come from tests/fim/profiles.lua (the plugin itself ships none -- see
-- lua/local-fim/profiles.lua); default is "qwen2.5-coder", override with
-- LOCAL_FIM_PROFILE.
--
-- Usage (from the repo root):
--   nvim --headless -l tests/fim/run.lua            # all cases, qwen2.5-coder
--   nvim --headless -l tests/fim/run.lua greet      # one case
--   LOCAL_FIM_PROFILE=qwen3.5-4b nvim --headless -l tests/fim/run.lua
--
-- All profiles share one endpoint by default (you swap the loaded model
-- locally and point `profile` at the matching bundle) -- to compare two
-- models side by side, run a second llama-server on another port and point
-- this harness at it with LOCAL_FIM_ENDPOINT:
--   LOCAL_FIM_PROFILE=qwen3.5-4b LOCAL_FIM_ENDPOINT=http://127.0.0.1:8013 \
--     nvim --headless -l tests/fim/run.lua

local src = debug.getinfo(1, "S").source:sub(2)
local here = vim.fn.fnamemodify(src, ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h")
vim.opt.runtimepath:append(root)

-- The plugin ships no built-in profiles (see lua/local-fim/profiles.lua) --
-- this harness uses the example profiles in tests/fim/profiles.lua (the same
-- ones documented in the README) so it has something concrete to run
-- against without requiring your personal Neovim config.
local example_profiles = dofile(here .. "/profiles.lua")

local fim = require("local-fim")
fim.setup({
  profile = vim.env.LOCAL_FIM_PROFILE or "qwen2.5-coder",
  profiles = example_profiles,
  endpoint = vim.env.LOCAL_FIM_ENDPOINT,
})
local cfg = fim.config
if not cfg.stop then
  error(
    ("no such profile %q in tests/fim/profiles.lua"):format(vim.env.LOCAL_FIM_PROFILE or "qwen2.5-coder"),
    0
  )
end
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

-- Tokens that should never survive into a completion regardless of profile --
-- covers both FIM-family families the plugin supports (completion-mode
-- <fim_*>/<filename>, infill-mode <|fim_*|>/<|file_sep|>/<|repo_name|>) plus
-- common eos/pad tokens. A profile's own `stop` list is checked in addition.
local GENERIC_LEAK_TOKENS = {
  "<fim_prefix>", "<fim_suffix>", "<fim_middle>", "<filename>",
  "<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>", "<|fim_pad|>",
  "<|file_sep|>", "<|repo_name|>", "<|endoftext|>", "<|im_end|>", "<|im_start|>",
}

local function trimmed_lines(text)
  local lines = {}
  for _, l in ipairs(vim.split(text or "", "\n")) do
    local t = vim.trim(l)
    if t ~= "" then
      lines[#lines + 1] = t
    end
  end
  return lines
end

-- Inspect one completion for known failure modes. Returns a list of
-- human-readable issue strings (empty when nothing looks wrong).
--   response: the decoded llama-server response (meta.response), or nil
--   suffix: the input_suffix sent for this request, to check for verbatim echo
--   stop: the profile's own stop-token list, checked alongside the generic set
local function find_issues(text, response, suffix, stop)
  local issues = {}
  if text == nil or text == "" then
    issues[#issues + 1] = "empty completion"
    return issues
  end
  if text:match("^%[error%]") then
    issues[#issues + 1] = "request failed: " .. text
    return issues
  end

  local leak_tokens = vim.deepcopy(GENERIC_LEAK_TOKENS)
  vim.list_extend(leak_tokens, stop or {})
  for _, tok in ipairs(leak_tokens) do
    if text:find(tok, 1, true) then
      issues[#issues + 1] = "leaked special token: " .. tok
    end
  end

  if response and response.stopped_limit then
    issues[#issues + 1] = ("hit n_predict limit with no natural stop (%s tokens)"):format(
      tostring(response.tokens_predicted)
    )
  end

  local lines = trimmed_lines(text)
  local run_start, run_line = 1, lines[1]
  for i = 2, #lines + 1 do
    if lines[i] ~= run_line then
      if lines[i - 1] and (i - run_start) >= 3 then
        issues[#issues + 1] = ('repeated line x%d: "%s"'):format(i - run_start, run_line)
      end
      run_start, run_line = i, lines[i]
    end
  end

  local suffix_lines = trimmed_lines(suffix)
  local completion_line_set = {}
  for _, l in ipairs(lines) do
    completion_line_set[l] = true
  end
  for i = 1, math.min(2, #suffix_lines) do
    local sline = suffix_lines[i]
    if #sline > 3 and completion_line_set[sline] then
      issues[#issues + 1] = ('echoes suffix line verbatim: "%s"'):format(sline)
    end
  end

  return issues
end

local function format_issues(issues)
  if #issues == 0 then
    return "issues: none"
  end
  local lines = { ("issues: %d"):format(#issues) }
  for _, issue in ipairs(issues) do
    lines[#lines + 1] = "  - " .. issue
  end
  return table.concat(lines, "\n")
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

  local without_issues = find_issues(without, without_meta and without_meta.response, suffix, cfg.stop)
  local withdep_issues = #deps > 0
      and find_issues(withdep, withdep_meta and withdep_meta.response, suffix, cfg.stop)
    or {}

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
    format_issues(without_issues),
    "",
    ("=== completion with %s ==="):format(dep_label),
    withdep,
    "",
    format_issues(withdep_issues),
  }
  local out_path = here .. "/" .. name .. ".output.txt"
  vim.fn.writefile(vim.split(table.concat(out, "\n"), "\n"), out_path)
  print("wrote " .. out_path)

  local summary = {}
  if #without_issues > 0 then
    summary[#summary + 1] = { variant = "no deps", issues = without_issues }
  end
  if #withdep_issues > 0 then
    summary[#summary + 1] = { variant = dep_label, issues = withdep_issues }
  end
  return summary
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

local all_flagged = {}
for _, name in ipairs(cases) do
  local flagged = run_case(name)
  if flagged and #flagged > 0 then
    all_flagged[#all_flagged + 1] = { name = name, flagged = flagged }
  end
end

print("")
print(("=== summary: profile %s ==="):format(cfg.profile))
if #all_flagged == 0 then
  print("no issues detected across " .. #cases .. " case(s)")
else
  for _, entry in ipairs(all_flagged) do
    for _, v in ipairs(entry.flagged) do
      print(("%s [%s]: %d issue(s)"):format(entry.name, v.variant, #v.issues))
      for _, issue in ipairs(v.issues) do
        print("  - " .. issue)
      end
    end
  end
end
