-- JSON utilities for MixDeck
-- Simple but functional JSON encode/decode for our preset configs

local json = {}

function json.encode(obj, indent)
  indent = indent or 0
  local indent_str = string.rep("  ", indent)
  local next_indent_str = string.rep("  ", indent + 1)

  if type(obj) == "nil" then
    return "null"
  elseif type(obj) == "boolean" then
    return obj and "true" or "false"
  elseif type(obj) == "number" then
    return tostring(obj)
  elseif type(obj) == "string" then
    -- Escape special characters
    local escaped = obj:gsub("\\", "\\\\")
                       :gsub('"', '\\"')
                       :gsub("\n", "\\n")
                       :gsub("\r", "\\r")
                       :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
  elseif type(obj) == "table" then
    -- Detect if it's an array or object
    local is_array = #obj > 0
    if is_array then
      local result = "[\n"
      for i, v in ipairs(obj) do
        result = result .. next_indent_str .. json.encode(v, indent + 1)
        if i < #obj then
          result = result .. ","
        end
        result = result .. "\n"
      end
      result = result .. indent_str .. "]"
      return result
    else
      local result = "{\n"
      local keys = {}
      for k in pairs(obj) do
        table.insert(keys, k)
      end
      table.sort(keys)
      for i, k in ipairs(keys) do
        result = result .. next_indent_str .. json.encode(k) .. ": " .. json.encode(obj[k], indent + 1)
        if i < #keys then
          result = result .. ","
        end
        result = result .. "\n"
      end
      result = result .. indent_str .. "}"
      return result
    end
  else
    return "null"
  end
end

function json.decode(json_str)
  local pos = 1
  local function skip_whitespace()
    while pos <= #json_str and json_str:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function decode_value()
    skip_whitespace()
    local char = json_str:sub(pos, pos)

    if char == '"' then
      pos = pos + 1
      local str = ""
      while pos <= #json_str do
        char = json_str:sub(pos, pos)
        if char == '"' then
          pos = pos + 1
          return str
        elseif char == "\\" then
          pos = pos + 1
          local next_char = json_str:sub(pos, pos)
          if next_char == "n" then
            str = str .. "\n"
          elseif next_char == "r" then
            str = str .. "\r"
          elseif next_char == "t" then
            str = str .. "\t"
          elseif next_char == '"' or next_char == "\\" or next_char == "/" then
            str = str .. next_char
          else
            str = str .. next_char
          end
        else
          str = str .. char
        end
        pos = pos + 1
      end
      return str
    elseif char == "[" then
      pos = pos + 1
      local arr = {}
      skip_whitespace()
      if json_str:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        table.insert(arr, decode_value())
        skip_whitespace()
        char = json_str:sub(pos, pos)
        if char == "]" then
          pos = pos + 1
          return arr
        elseif char == "," then
          pos = pos + 1
        end
      end
    elseif char == "{" then
      pos = pos + 1
      local obj = {}
      skip_whitespace()
      if json_str:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip_whitespace()
        local key = decode_value()
        skip_whitespace()
        if json_str:sub(pos, pos) ~= ":" then
          error("Expected ':' in JSON object")
        end
        pos = pos + 1
        obj[key] = decode_value()
        skip_whitespace()
        char = json_str:sub(pos, pos)
        if char == "}" then
          pos = pos + 1
          return obj
        elseif char == "," then
          pos = pos + 1
        end
      end
    elseif char == "t" or char == "f" then
      if json_str:sub(pos, pos + 3) == "true" then
        pos = pos + 4
        return true
      elseif json_str:sub(pos, pos + 4) == "false" then
        pos = pos + 5
        return false
      end
    elseif char == "n" then
      if json_str:sub(pos, pos + 3) == "null" then
        pos = pos + 4
        return nil
      end
    else
      local num_str = ""
      while pos <= #json_str and json_str:sub(pos, pos):match("[0-9.eE+-]") do
        num_str = num_str .. json_str:sub(pos, pos)
        pos = pos + 1
      end
      return tonumber(num_str)
    end
  end

  return decode_value()
end

return json
