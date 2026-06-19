-- Cross-file context from the language server. On a completion trigger we take
-- the identifiers the cursor is typing against, ask the LSP for their
-- definitions, and return the enclosing code regions as { filename, text }
-- entries for the FIM prompt's `extra` list. Additive to the ring buffer; fully
-- async with a hard deadline so a slow or absent server never blocks a request.
local M = {}

-- Treesitter leaf types we treat as resolvable symbols. Names vary per grammar
-- but these cover the common identifier/reference nodes.
local IDENT_TYPES = {
  identifier = true,
  type_identifier = true,
  field_identifier = true,
  property_identifier = true,
  shorthand_property_identifier = true,
  namespace_identifier = true,
  constant = true,
}

-- Walk named/anonymous children overlapping [start_row, end_row], collecting
-- identifier-like leaves. Children are positionally ordered, so we stop once a
-- child begins past the region.
local function collect_idents(node, start_row, end_row, end_col, acc)
  for child in node:iter_children() do
    local sr, sc, er = child:range()
    if sr > end_row then
      break
    end
    if er >= start_row then
      if IDENT_TYPES[child:type()] then
        if not (sr == end_row and sc >= end_col) then
          acc[#acc + 1] = { row = sr, col = sc, node = child }
        end
      else
        collect_idents(child, start_row, end_row, end_col, acc)
      end
    end
  end
end

-- Fallback when no treesitter parser is available: regex word starts in the
-- prefix region. The LSP self-filters non-symbols by returning no definition.
local function naive_positions(bufnr, row, col, start_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, row + 1, false)
  local positions = {}
  for i, line in ipairs(lines) do
    local lrow = start_row + i - 1
    local limit = (lrow == row) and col or #line
    local init = 1
    while true do
      local s, e = line:find("[%a_][%w_]*", init)
      if not s or s - 1 >= limit then
        break
      end
      positions[#positions + 1] = { row = lrow, col = s - 1, name = line:sub(s, e) }
      init = e + 1
    end
  end
  return positions
end

local function candidate_positions(bufnr, row, col, cfg)
  local start_row = math.max(0, row - cfg.max_prefix_lines)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return naive_positions(bufnr, row, col, start_row)
  end
  local trees = parser:parse()
  local root = trees[1]:root()
  local nodes = {}
  collect_idents(root, start_row, row, col, nodes)
  local positions = {}
  for _, n in ipairs(nodes) do
    positions[#positions + 1] = { row = n.row, col = n.col, name = vim.treesitter.get_node_text(n.node, bufnr) }
  end
  return positions
end

-- Nearest the cursor first, deduped by name, capped to max_symbols.
local function dedupe_and_cap(positions, cap)
  table.sort(positions, function(a, b)
    if a.row ~= b.row then
      return a.row > b.row
    end
    return a.col > b.col
  end)
  local out, seen = {}, {}
  for _, p in ipairs(positions) do
    if p.name and p.name ~= "" and not seen[p.name] then
      seen[p.name] = true
      out[#out + 1] = p
      if #out >= cap then
        break
      end
    end
  end
  return out
end

-- When the cursor sits just after a member operator (`transport.`, `a?.b`,
-- `p->x`, `T::y`), recover the receiver identifier and its position so we can
-- resolve its *type* and feed the model the members available on it. The line
-- may be mid-edit (a partially typed member), so this scans text rather than
-- the syntax tree. Returns { row, col, name } or nil.
local function member_receiver(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local before = line:sub(1, col):gsub("[%w_]*$", "") -- drop the partial member being typed
  if not (before:match("%.%s*$") or before:match("%-%>%s*$") or before:match("::%s*$")) then
    return nil
  end
  local recv = before:gsub("[%s%.:>%-%?]*$", "") -- strip the operator and trailing space
  local s = recv:find("[%w_]+$")
  if not s then
    return nil -- receiver is not a plain identifier (e.g. a call result)
  end
  return { row = row, col = s - 1, name = recv:sub(s) }
end

-- A definition result may be a Location or a LocationLink. Pull the target uri
-- and the start of the most specific range we have.
local function loc_target(loc)
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if not uri or not range then
    return nil
  end
  return uri, range.start.line, range.start.character
end

-- Definition-ish ancestor node types, matched as substrings across grammars.
local function is_definition_node(t)
  return t:find("function")
    or t:find("method")
    or t:find("class")
    or t:find("declaration")
    or t:find("definition")
    or t:find("struct")
    or t:find("interface")
    or t:find("enum")
    or t:find("type_alias")
end

-- Extract the enclosing definition region at (defrow, defcol) in tbuf, capped to
-- max_def_lines. Falls back to a fixed window when treesitter can't help.
local function enclosing_text(tbuf, defrow, defcol, cfg)
  local total = vim.api.nvim_buf_line_count(tbuf)
  local ok, parser = pcall(vim.treesitter.get_parser, tbuf)
  if ok and parser then
    parser:parse()
    local node = vim.treesitter.get_node({ bufnr = tbuf, pos = { defrow, defcol } })
    while node do
      if is_definition_node(node:type()) then
        local sr, _, er = node:range()
        er = math.min(er, sr + cfg.lsp.max_def_lines - 1)
        return table.concat(vim.api.nvim_buf_get_lines(tbuf, sr, er + 1, false), "\n")
      end
      node = node:parent()
    end
  end
  local er = math.min(total, defrow + cfg.lsp.max_def_lines)
  return table.concat(vim.api.nvim_buf_get_lines(tbuf, defrow, er, false), "\n")
end

-- Turn raw definition locations into deduped { filename, text } entries. Skips
-- targets in the source buffer (already covered by prefix/suffix in v1). `seen`
-- is shared across calls so a type-def doesn't duplicate a plain def.
local function build_entries(locs, src_bufnr, cfg, seen)
  local src_name = vim.api.nvim_buf_get_name(src_bufnr)
  local entries = {}
  for _, loc in ipairs(locs) do
    local uri, drow, dcol = loc_target(loc)
    if uri then
      local fname = vim.uri_to_fname(uri)
      local key = fname .. ":" .. drow
      if fname ~= src_name and not seen[key] then
        seen[key] = true
        local tbuf = vim.uri_to_bufnr(uri)
        vim.fn.bufload(tbuf)
        local text = enclosing_text(tbuf, drow, dcol, cfg)
        if text and not text:match("^%s*$") then
          entries[#entries + 1] = { filename = vim.fn.fnamemodify(fname, ":."), text = text }
        end
      end
    end
  end
  return entries
end

-- Resolve definitions for the symbols around (row, col) and call back with a
-- list of { filename, text } entries. Always calls back exactly once: on all
-- responses, on the deadline, or immediately when there is nothing to do.
function M.collect(cfg, bufnr, row, col, callback)
  if not (cfg.lsp and cfg.lsp.enabled) then
    return callback({})
  end
  if #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
    return callback({})
  end

  -- Definitions for the nearby identifiers, plus the *type* definition of a
  -- member-access receiver so the model sees what `receiver.` can call.
  local positions = dedupe_and_cap(candidate_positions(bufnr, row, col, cfg), cfg.lsp.max_symbols)
  local requests = {}
  for _, pos in ipairs(positions) do
    requests[#requests + 1] = { method = "textDocument/definition", pos = pos, type = false }
  end
  local receiver = member_receiver(bufnr, row, col)
  if receiver then
    requests[#requests + 1] = { method = "textDocument/typeDefinition", pos = receiver, type = true }
  end
  if #requests == 0 then
    return callback({})
  end

  local def_locs, type_locs = {}, {}
  local pending = #requests
  local done = false
  local function finish()
    if done then
      return
    end
    done = true
    -- Shared dedupe; type-def entries come last so the receiver's members sit
    -- nearest the FIM region in the assembled prompt.
    local seen = {}
    local entries = build_entries(def_locs, bufnr, cfg, seen)
    for _, e in ipairs(build_entries(type_locs, bufnr, cfg, seen)) do
      entries[#entries + 1] = e
    end
    callback(entries)
  end

  vim.defer_fn(finish, cfg.lsp.timeout_ms)

  for _, req in ipairs(requests) do
    local bucket = req.type and type_locs or def_locs
    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = req.pos.row, character = req.pos.col },
    }
    vim.lsp.buf_request_all(bufnr, req.method, params, function(res)
      for _, r in pairs(res or {}) do
        local result = r.result
        if result then
          if result.uri or result.targetUri then
            result = { result }
          end
          for _, loc in ipairs(result) do
            bucket[#bucket + 1] = loc
          end
        end
      end
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end)
  end
end

return M
