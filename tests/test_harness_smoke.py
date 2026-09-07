"""Proves the harness can load mixdeck.lua under the mock and reach its functions."""


def test_loads_and_exposes_state(mixdeck):
    assert mixdeck.md["name"] == "MixDeck"
    assert mixdeck.md["version"] != ""


def test_exposes_callbacks(mixdeck):
    for name in ("create_preset", "delete_preset", "export_preset", "batch_export"):
        assert mixdeck.fns[name] is not None, name


def test_create_preset_round_trips_to_disk(mixdeck):
    assert mixdeck.fns.create_preset("Bass Isolated", "global") is not False
    assert "Bass Isolated" in mixdeck.preset_names()
    assert mixdeck.global_config.exists()
