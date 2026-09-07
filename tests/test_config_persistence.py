"""Config writes are full-file replacements, so every write has to preserve the
keys it does not own. These cover the settings that used to get dropped."""


def read_global(mixdeck):
    return mixdeck.global_config.read_text(encoding="utf-8")


def test_saving_a_preset_keeps_the_export_path(mixdeck):
    mixdeck.md["global_export_path"] = "C:/Exports"
    mixdeck.fns.save_config("global")

    mixdeck.fns.create_preset("Bass", "global")
    preset = mixdeck.fns.get_preset("Bass")
    mixdeck.fns.save_preset_to_scope(preset, "global")

    assert "C:/Exports" in read_global(mixdeck), "export_path was dropped by the preset save"


def test_saving_a_preset_keeps_format_and_bitrate(mixdeck):
    mixdeck.md["format"] = "flac"
    mixdeck.md["bitrate"] = "128k"
    mixdeck.fns.save_config("global")

    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.save_preset_to_scope(mixdeck.fns.get_preset("Bass"), "global")

    text = read_global(mixdeck)
    assert "flac" in text, "format was dropped by the preset save"
    assert "128k" in text, "bitrate was dropped by the preset save"


def test_saving_a_preset_keeps_the_track_automap(mixdeck):
    mixdeck.add_track("Bass DI")
    mixdeck.fns.set_permanent_track_automap("<ROOT> > Bass", "<ROOT> > Bass DI")

    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.save_preset_to_scope(mixdeck.fns.get_preset("Bass"), "global")

    assert "Bass DI" in read_global(mixdeck), "track_automap was dropped by the preset save"


def test_settings_survive_a_reload(mixdeck):
    mixdeck.md["global_export_path"] = "C:/Exports"
    mixdeck.md["format"] = "flac"
    mixdeck.fns.save_config("global")
    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.save_preset_to_scope(mixdeck.fns.get_preset("Bass"), "global")

    mixdeck.reload()

    assert mixdeck.md["global_export_path"] == "C:/Exports"
    assert mixdeck.md["format"] == "flac"
    assert "Bass" in mixdeck.preset_names()


def test_saving_a_project_preset_keeps_the_default_state(mixdeck):
    mixdeck.add_track("Kick", pan=-0.5)
    assert mixdeck.fns.save_default_state() is True

    had_state, count = mixdeck.fns.get_default_state_status()
    assert had_state and count == 1

    mixdeck.fns.create_preset("Verse", "project")
    mixdeck.fns.save_preset_to_scope(mixdeck.fns.get_preset("Verse"), "project")

    had_state, count = mixdeck.fns.get_default_state_status()
    assert had_state, "default_state was destroyed by saving a project preset"
    assert count == 1


def test_project_remap_survives_a_preset_save(mixdeck):
    mixdeck.fns.set_project_track_remap("<ROOT> > Old", "<ROOT> > New")
    mixdeck.fns.create_preset("Verse", "project")
    mixdeck.fns.save_preset_to_scope(mixdeck.fns.get_preset("Verse"), "project")

    mixdeck.reload()
    assert mixdeck.fns.get_project_track_remap_target("<ROOT> > Old") == "<ROOT> > New"
