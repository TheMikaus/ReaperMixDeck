import pytest

# Malformed input must fail fast. A runaway loop is bounded with a Lua count hook,
# so a regression surfaces as a failed assertion instead of hanging the test run.
BOUNDED_DECODE = """
function(text)
  debug.sethook(function() error("INSTRUCTION_BUDGET_EXCEEDED", 2) end, "", 2000000)
  local ok, result = pcall(function() return json.decode(text) end)
  debug.sethook()
  return ok, tostring(result)
end
"""

MALFORMED = [
    "[1",
    '["Bass"',
    "[1,",
    "[",
    '{"a": "b"',
    '{"a"',
    '{"version":"1.3.33","presets":[{"name":"Bass"',
    "{",
]


@pytest.mark.parametrize("text", MALFORMED)
def test_malformed_input_errors_instead_of_hanging(lua_json, text):
    """A config truncated by a crash or a full disk must not lock up Reaper."""
    decode = lua_json.eval(BOUNDED_DECODE)
    ok, result = decode(text)
    assert not ok, "expected a decode error for %r, got a value back" % text
    assert "INSTRUCTION_BUDGET_EXCEEDED" not in result, (
        "decode() ran away on %r instead of erroring: %s" % (text, result)
    )


def test_round_trips_a_preset_config(lua_json):
    assert lua_json.execute(
        """
        local original = {
          version = "1.3.33",
          export_path = "C:/Exports",
          presets = {
            { name = "Bass", scope = "global", routing = { ["<ROOT> > Bass"] = "L" } },
          },
        }
        local decoded = json.decode(json.encode(original))
        assert(decoded.version == "1.3.33", "version lost")
        assert(decoded.export_path == "C:/Exports", "export_path lost")
        assert(#decoded.presets == 1, "presets lost")
        assert(decoded.presets[1].routing["<ROOT> > Bass"] == "L", "routing lost")
        return "ok"
        """
    ) == "ok"


def test_empty_preset_list_round_trips_as_a_list(lua_json):
    assert lua_json.execute(
        """
        local decoded = json.decode(json.encode({ presets = {} }))
        local count = 0
        for _ in ipairs(decoded.presets or {}) do count = count + 1 end
        return count
        """
    ) == 0


def test_escapes_control_characters(lua_json):
    assert lua_json.execute(
        r"""
        local encoded = json.encode({ name = "Gtr\1Left" })
        assert(not encoded:find("\1", 1, true), "raw control byte survived encoding: " .. encoded)
        assert(json.decode(encoded).name == "Gtr\1Left", "control char did not round-trip")
        return "ok"
        """
    ) == "ok"


def test_rejects_trailing_garbage(lua_json):
    decode = lua_json.eval(BOUNDED_DECODE)
    ok, _ = decode('{"a": 1} and then some junk')
    assert not ok, "trailing garbage should be rejected, not silently ignored"
