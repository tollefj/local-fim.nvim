local M = {}

---@class local_fim.Tokens
---@field filename string
---@field prefix string
---@field suffix string
---@field middle string

---@class local_fim.ServerSpec
---@field hf? string
---@field gguf? string
---@field model_dir? string
---@field ctx integer

---@class local_fim.Profile
---@field mode "completion"|"infill"
---@field n_predict integer
---@field temperature number
---@field top_k integer
---@field top_p number
---@field t_max_predict_ms integer
---@field stop string[]
---@field tokens? local_fim.Tokens
---@field server? local_fim.ServerSpec
---@field repeat_penalty? number
---@field dry_multiplier? number
---@field dry_base? number
---@field dry_allowed_length? integer
---@field dry_penalty_last_n? integer
---@field dry_sequence_breakers? string[]

---@type local_fim.Profile
M.profile_defaults = {
  mode = "completion",
  n_predict = 256,
  temperature = 0.5,
  top_k = 40,
  top_p = 0.9,
  t_max_predict_ms = 1000,
  tokens = {
    filename = "<filename>",
    prefix = "<fim_prefix>",
    suffix = "<fim_suffix>",
    middle = "<fim_middle>",
  },
}

---@type table<string, local_fim.Profile>
M.profiles = {}

---@param profile local_fim.Profile
---@return local_fim.Profile
function M.resolve(profile)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.profile_defaults), vim.deepcopy(profile or {}))
end

local function list_of_strings(t)
  if type(t) ~= "table" then
    return false
  end
  for _, v in ipairs(t) do
    if type(v) ~= "string" then
      return false
    end
  end
  return true
end

---@param p local_fim.Profile
---@return boolean ok, string? err
function M.validate(p)
  if type(p) ~= "table" then
    return false, "profile is not a table"
  end
  if p.mode ~= "completion" and p.mode ~= "infill" then
    return false, ('mode must be "completion" or "infill" (got %s)'):format(vim.inspect(p.mode))
  end
  if type(p.n_predict) ~= "number" or p.n_predict <= 0 then
    return false, "n_predict must be a positive number"
  end
  if not list_of_strings(p.stop) then
    return false, "stop must be a list of strings"
  end
  if p.mode == "completion" then
    if type(p.tokens) ~= "table" then
      return false, "completion mode requires a tokens table"
    end
    for _, k in ipairs({ "prefix", "suffix", "middle", "filename" }) do
      if type(p.tokens[k]) ~= "string" then
        return false, ("tokens.%s must be a string"):format(k)
      end
    end
  end
  for _, k in ipairs({ "repeat_penalty", "dry_multiplier", "dry_base", "dry_allowed_length", "dry_penalty_last_n" }) do
    if p[k] ~= nil and type(p[k]) ~= "number" then
      return false, (k .. " must be a number")
    end
  end
  if p.dry_sequence_breakers ~= nil and not list_of_strings(p.dry_sequence_breakers) then
    return false, "dry_sequence_breakers must be a list of strings"
  end
  if p.server ~= nil then
    local s = p.server
    if type(s) ~= "table" then
      return false, "server must be a table"
    end
    if s.hf == nil and s.gguf == nil then
      return false, "server must define hf and/or gguf"
    end
    if s.hf ~= nil and type(s.hf) ~= "string" then
      return false, "server.hf must be a string"
    end
    if s.gguf ~= nil and type(s.gguf) ~= "string" then
      return false, "server.gguf must be a string"
    end
    if type(s.ctx) ~= "number" then
      return false, "server.ctx must be a number"
    end
  end
  return true
end

return M
