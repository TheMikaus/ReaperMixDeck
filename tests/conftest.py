"""Test harness for MixDeck.

mixdeck.lua is a script, not a module: it runs init() and main_loop() at load time
and keeps its state in locals. The one seam is `ui.init(md, fns)` — so we stub
dofile() for ui.lua and capture both tables from that call.
"""
import os
import pathlib

import pytest
from lupa import lua54

PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent
TESTS_DIR = PROJECT_DIR / "tests"


def _lua_path(p):
    return str(p).replace("\\", "/")


class MixDeck:
    """A loaded mixdeck.lua plus its mock Reaper."""

    def __init__(self, lua, md, fns, rmock, resource_path, tmp_path):
        self.lua = lua
        self.md = md
        self.fns = fns
        self.rmock = rmock
        self.resource_path = pathlib.Path(resource_path)
        self.tmp_path = pathlib.Path(tmp_path)

    def add_track(self, name, depth=0, pan=0.0, vol=1.0, mute=0, solo=0, items=0):
        """Append a track to the mock project. Builds a real Lua table, since Lua
        indexing a Python dict raises KeyError on absent keys instead of nil."""
        spec = self.lua.table_from({
            "name": name, "depth": depth, "pan": pan,
            "vol": vol, "mute": mute, "solo": solo, "items": items,
        })
        return self.rmock.add_track(spec)

    def reload(self):
        self.fns.load_config()

    @property
    def global_config(self):
        return self.resource_path / "Scripts" / "MixDeck" / "mixdeck_global.json"

    def project_config(self, name):
        return self.tmp_path / ("%s.mixdeck.json" % name)

    def eval(self, src):
        return self.lua.execute(src)

    def preset_names(self):
        return [p["name"] for p in self.md["presets"].values()]


def _new_runtime(tmp_path, resource_path):
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)

    def mkdir(path):
        try:
            os.makedirs(str(path).replace("\\", "/"), exist_ok=True)
        except OSError:
            return 0
        return 1

    lua.globals()["__host_mkdir"] = mkdir
    lua.execute('RMOCK = dofile("%s")' % _lua_path(TESTS_DIR / "reaper_mock.lua"))
    rmock = lua.globals()["RMOCK"]
    rmock["resource_path"] = _lua_path(resource_path)
    return lua, rmock


@pytest.fixture
def mixdeck(tmp_path):
    """Load mixdeck.lua under a mock Reaper with an empty saved project."""
    resource_path = tmp_path / "reaper_resource"
    os.makedirs(resource_path, exist_ok=True)

    lua, rmock = _new_runtime(tmp_path, resource_path)
    rmock.set_project(_lua_path(tmp_path / "Song.rpp"))

    # Stub ui.lua and capture the (md, fns) tables it is handed.
    lua.execute(
        """
        _CAPTURED = {}
        local real_dofile = dofile
        _G.dofile = function(path)
          if tostring(path):match("ui%.lua$") then
            return {
              init = function(md, fns) _CAPTURED.md = md; _CAPTURED.fns = fns end,
              draw = function() return false end,
              destroy = function() end,
            }
          end
          return real_dofile(path)
        end
        """
    )
    lua.execute('dofile("%s")' % _lua_path(PROJECT_DIR / "mixdeck.lua"))

    captured = lua.globals()["_CAPTURED"]
    return MixDeck(lua, captured["md"], captured["fns"], rmock, resource_path, tmp_path)


@pytest.fixture
def lua_json():
    """A Lua runtime with json_utils.lua loaded as the global `json`. No Reaper needed."""
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute('json = dofile("%s")' % _lua_path(PROJECT_DIR / "json_utils.lua"))
    return lua


@pytest.fixture
def lua_plain():
    """A bare Lua 5.4 runtime with package.path pointing at the project."""
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        "package.path = package.path .. ';%s'" % _lua_path(PROJECT_DIR / "?.lua")
    )
    return lua
