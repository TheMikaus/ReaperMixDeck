-- JSON utilities for MixDeck
--
-- Strict enough for config files: every parse either returns a value or raises.
-- It must never loop forever on truncated input, because a config half-written by
-- a crash would otherwise hang Reaper with no way out (pcall cannot break a loop).

local json = {}

local MAX_DEPTH = 64

-- ============================================================================
-- ENCODE
-- ============================================================================

local ESCAPES = {
  ['"']    = '\\"',
  ['\\']   = '\\\\',
  ['\b']   = '\\b',
  ['\f']   = '\\f',
  ['\n']   = '\\n',
  ['\r']   = '\\r',
  ['\t']   = '\\t',
}

local function escape_char(c)
  local mapped = ESCAPES[c]
  if mapped then return mapped end
  return string.format("\\u%04x", string.byte(c))
end

local function encode_string(s)
  -- Escape the structural characters plus every C0 control byte and DEL.
  return '"' .. s:gsub('[%z\1-\31\127"\\]', escape_char) .. '"'
end

local function encode_number(n)
  if n ~= n then error("cannot encode nan as JSON") end
  if n == math.huge or n == -math.huge then error("cannot encode inf as JSON") end
  if math.type and math.type(n) == "integer" then
    return string.format("%d", n)
  end
  -- %.14g round-trips a double without trailing float noise.
  return string.format("%.14g", n)
end

local function is_array(t)
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    count = count + 1
  end
  -- Contiguous 1..n, no holes.
  return count == #t
end

local function encode_value(obj, indent, depth)
  if depth > MAX_DEPTH then
    error("JSON nesting deeper than " .. MAX_DEPTH .. " levels")
  end

  local t = type(obj)
  local indent_str = string.rep("  ", indent)
  local next_indent_str = string.rep("  ", indent + 1)

  if obj == nil then
    return "null"
  elseif t == "boolean" then
    return obj and "true" or "false"
  elseif t == "number" then
    return encode_number(obj)
  elseif t == "string" then
    return encode_string(obj)
  elseif t == "table" then
    local parts = {}
    if is_array(obj) and #obj > 0 then
      for i, v in ipairs(obj) do
        parts[i] = next_indent_str .. encode_value(v, indent + 1, depth + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "]"
    end

    -- Object. Sort keys so a config file has a stable byte layout between saves.
    local keys = {}
    for k in pairs(obj) do
      if type(k) ~= "string" and type(k) ~= "number" then
        error("cannot encode table key of type " .. type(k))
      end
      keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    if #keys == 0 then
      return "{}"
    end

    for i, k in ipairs(keys) do
      parts[i] = next_indent_str .. encode_string(tostring(k)) .. ": "
        .. encode_value(obj[k], indent + 1, depth + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "}"
  end

  error("cannot encode value of type " .. t)
end

function json.encode(obj, indent)
  return encode_value(obj, indent or 0, 1)
end

-- ============================================================================
-- DECODE
-- ============================================================================

local function utf8_char(code)
  if utf8 and utf8.char then
    return utf8.char(code)
  end
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
  end
  return string.char(
    0xE0 + math.floor(code / 0x1000),
    0x80 + (math.floor(code / 0x40) % 0x40),
    0x80 + (code % 0x40)
  )
end

function json.decode(json_str)
  if type(json_str) ~= "string" then
    error("json.decode expects a string, got " .. type(json_str))
  end

  local pos = 1
  local len = #json_str

  local function fail(what)
    error("JSON parse error at position " .. pos .. ": " .. what, 0)
  end

  local function peek()
    if pos > len then return nil end
    return json_str:sub(pos, pos)
  end

  local function skip_whitespace()
    while pos <= len and json_str:sub(pos, pos):match("[ \t\r\n]") do
      pos = pos + 1
    end
  end

  -- Consumes one character, erroring at end of input. Every loop in the parser
  -- goes through expect() or advances pos unconditionally, so none can spin.
  local function expect(char, context)
    skip_whitespace()
    local c = peek()
    if c == nil then
      fail("unexpected end of input, expected '" .. char .. "'" .. (context or ""))
    end
    if c ~= char then
      fail("expected '" .. char .. "' but found '" .. c .. "'" .. (context or ""))
    end
    pos = pos + 1
  end

  local decode_value

  local function decode_string()
    pos = pos + 1  -- opening quote
    local parts = {}
    while true do
      local c = peek()
      if c == nil then fail("unterminated string") end
      pos = pos + 1

      if c == '"' then
        return table.concat(parts)
      elseif c == "\\" then
        local esc = peek()
        if esc == nil then fail("unterminated escape sequence") end
        pos = pos + 1
        if esc == "n" then parts[#parts + 1] = "\n"
        elseif esc == "r" then parts[#parts + 1] = "\r"
        elseif esc == "t" then parts[#parts + 1] = "\t"
        elseif esc == "b" then parts[#parts + 1] = "\b"
        elseif esc == "f" then parts[#parts + 1] = "\f"
        elseif esc == '"' or esc == "\\" or esc == "/" then parts[#parts + 1] = esc
        elseif esc == "u" then
          local hex = json_str:sub(pos, pos + 3)
          if #hex < 4 or not hex:match("^%x%x%x%x$") then
            fail("malformed \\u escape")
          end
          pos = pos + 4
          parts[#parts + 1] = utf8_char(tonumber(hex, 16))
        else
          fail("unknown escape '\\" .. esc .. "'")
        end
      else
        parts[#parts + 1] = c
      end
    end
  end

  local function decode_number()
    local start = pos
    if peek() == "-" then pos = pos + 1 end
    while pos <= len and json_str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    if peek() == "." then
      pos = pos + 1
      while pos <= len and json_str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    local e = peek()
    if e == "e" or e == "E" then
      pos = pos + 1
      local sign = peek()
      if sign == "+" or sign == "-" then pos = pos + 1 end
      while pos <= len and json_str:sub(pos, pos):match("[0-9]") do pos = pos + 1 end
    end
    local text = json_str:sub(start, pos - 1)
    local value = tonumber(text)
    if value == nil then
      pos = start
      fail("malformed number")
    end
    return value
  end

  local function decode_literal(word, value)
    if json_str:sub(pos, pos + #word - 1) == word then
      pos = pos + #word
      return value
    end
    fail("unexpected token")
  end

  local function decode_array(depth)
    pos = pos + 1  -- opening bracket
    local arr = {}
    skip_whitespace()
    if peek() == "]" then
      pos = pos + 1
      return arr
    end
    while true do
      arr[#arr + 1] = decode_value(depth + 1)
      skip_whitespace()
      local c = peek()
      if c == nil then fail("unterminated array") end
      if c == "]" then
        pos = pos + 1
        return arr
      elseif c == "," then
        pos = pos + 1
      else
        fail("expected ',' or ']' in array but found '" .. c .. "'")
      end
    end
  end

  local function decode_object(depth)
    pos = pos + 1  -- opening brace
    local obj = {}
    skip_whitespace()
    if peek() == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_whitespace()
      if peek() ~= '"' then fail("expected a quoted object key") end
      local key = decode_string()
      expect(":", " after object key")
      obj[key] = decode_value(depth + 1)
      skip_whitespace()
      local c = peek()
      if c == nil then fail("unterminated object") end
      if c == "}" then
        pos = pos + 1
        return obj
      elseif c == "," then
        pos = pos + 1
      else
        fail("expected ',' or '}' in object but found '" .. c .. "'")
      end
    end
  end

  decode_value = function(depth)
    depth = depth or 1
    if depth > MAX_DEPTH then
      fail("nesting deeper than " .. MAX_DEPTH .. " levels")
    end
    skip_whitespace()
    local c = peek()
    if c == nil then fail("unexpected end of input") end

    if c == '"' then return decode_string() end
    if c == "[" then return decode_array(depth) end
    if c == "{" then return decode_object(depth) end
    if c == "t" then return decode_literal("true", true) end
    if c == "f" then return decode_literal("false", false) end
    if c == "n" then return decode_literal("null", nil) end
    if c:match("[%-0-9]") then return decode_number() end
    fail("unexpected character '" .. c .. "'")
  end

  local result = decode_value(1)
  skip_whitespace()
  if pos <= len then
    fail("trailing content after the top-level value")
  end
  return result
end

return json
