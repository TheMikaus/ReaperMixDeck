"""Metronome control during export/recording, and the as-is reference render."""
import pathlib

import pytest


def render_writes_output(mixdeck, extension="mp3"):
    def hook(rmock):
        folder = rmock["project_info_str"]["RENDER_FILE"]
        pattern = rmock["project_info_str"]["RENDER_PATTERN"]
        out = pathlib.Path(folder) / ("%s.%s" % (pattern, extension))
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"fake audio")

    mixdeck.rmock["render_hook"] = hook


@pytest.fixture
def project(mixdeck):
    mixdeck.add_track("Bass")
    mixdeck.add_track("Gtr")
    mixdeck.md["global_export_path"] = str(mixdeck.tmp_path / "out").replace("\\", "/")
    render_writes_output(mixdeck)
    return mixdeck


def make_preset(mixdeck, name):
    mixdeck.fns.create_preset(name, "global")
    mixdeck.fns.update_preset_routing(name, "<ROOT> > Bass", "L")
    return mixdeck.fns.get_preset(name)


def renders(mixdeck):
    return list(mixdeck.rmock["renders"].values())


# ── metronome ───────────────────────────────────────────────────────────────

def test_metronome_state_is_readable(project):
    assert project.fns.get_metronome_enabled() is False
    project.fns.set_metronome_enabled(True)
    assert project.fns.get_metronome_enabled() is True


def test_setting_the_same_state_does_not_toggle(project):
    """40364 is a toggle, not a setter, so firing it blindly would flip the
    metronome to the wrong state."""
    project.fns.set_metronome_enabled(False)
    assert project.rmock["metronome_toggles"] == 0

    project.fns.set_metronome_enabled(True)
    assert project.rmock["metronome_toggles"] == 1
    project.fns.set_metronome_enabled(True)
    assert project.rmock["metronome_toggles"] == 1


def test_set_metronome_enabled_returns_the_previous_state(project):
    assert project.fns.set_metronome_enabled(True) is False
    assert project.fns.set_metronome_enabled(False) is True


# ── the export click is a click *source* track, not the transport metronome ──
#
# Turning on the transport metronome does not reliably put a click in a render;
# it is a monitoring feature whose routing the script does not control. The
# renderable click is a real item on a real track.

def test_click_track_exists_during_the_render(project):
    project.md["metronome_in_export"] = True
    project.fns.export_preset(make_preset(project, "Bass Only"))

    assert renders(project)[0]["click_track"] is True, "no click track present at render time"


def test_no_click_track_when_disabled(project):
    project.md["metronome_in_export"] = False
    project.fns.export_preset(make_preset(project, "Bass Only"))
    assert renders(project)[0]["click_track"] is False


def test_click_track_is_removed_after_export(project):
    project.md["metronome_in_export"] = True
    before = len(list(project.rmock["tracks"].values()))

    project.fns.export_preset(make_preset(project, "Bass Only"))

    assert project.rmock.find_click_track() is None, "click track left behind"
    assert len(list(project.rmock["tracks"].values())) == before


def test_click_track_is_removed_even_when_the_render_throws(project):
    project.md["metronome_in_export"] = True

    def explode(rmock):
        raise RuntimeError("render blew up")

    project.rmock["render_hook"] = explode
    ok, _err = project.fns.export_preset(make_preset(project, "Bass Only"))

    assert ok is False
    assert project.rmock.find_click_track() is None, "click track left behind after a failure"


def test_click_track_does_not_disturb_the_restore(project):
    """It is appended last so the index-keyed mixer restore still lines up."""
    project.md["metronome_in_export"] = True
    before = project.rmock.mixer_state()

    project.fns.export_preset(make_preset(project, "Bass Only"))

    after = project.rmock.mixer_state()
    for i in range(1, len(before) + 1):
        for field in ("pan", "mute", "solo", "vol"):
            assert before[i][field] == after[i][field], (
                "%s.%s not restored" % (before[i]["name"], field)
            )


def test_click_track_is_not_muted_by_routing(project):
    """Routing mutes everything it does not place. The click is added after
    routing runs, so it survives."""
    project.md["metronome_in_export"] = True
    seen = {}

    def hook(rmock):
        click = rmock.find_click_track()
        seen["muted"] = click and click["mute"] or 0
        folder = rmock["project_info_str"]["RENDER_FILE"]
        pattern = rmock["project_info_str"]["RENDER_PATTERN"]
        out = __import__("pathlib").Path(folder) / ("%s.mp3" % pattern)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"fake audio")

    project.rmock["render_hook"] = hook
    project.fns.export_preset(make_preset(project, "Bass Only"))

    assert seen["muted"] == 0, "the click track got muted by routing"


def test_click_source_availability_is_reported(project):
    assert project.fns.click_source_available() is True

    project.rmock["click_source_supported"] = False
    assert project.fns.click_source_available() is False


def test_export_still_succeeds_without_a_click_source(project):
    """A build with no click source should still export — just without a click,
    reported in the log rather than failing the render."""
    project.rmock["click_source_supported"] = False
    project.md["metronome_in_export"] = True

    ok = project.fns.export_preset(make_preset(project, "Bass Only"))
    assert ok is True
    assert renders(project)[0]["click_track"] is False


def test_the_recording_metronome_is_still_the_transport_one(project):
    """Two different mechanisms on purpose: the recording click is the transport
    metronome, because that is what you monitor while tracking."""
    project.fns.set_metronome_for_recording(True)
    assert project.rmock["metronome_on"] is True

    project.md["metronome_in_export"] = True
    project.fns.export_preset(make_preset(project, "Bass Only"))
    # The export click does not touch the transport metronome either way.
    assert project.rmock["metronome_on"] is True


def test_recording_metronome_is_persistent(project):
    """Unlike the export click, this one is meant to stay on for tracking."""
    assert project.fns.set_metronome_for_recording(True) is True
    assert project.fns.get_metronome_enabled() is True

    project.reload()
    assert project.md["metronome_in_recording"] is True


def test_recording_metronome_can_be_turned_off(project):
    project.fns.set_metronome_for_recording(True)
    project.fns.set_metronome_for_recording(False)
    assert project.fns.get_metronome_enabled() is False


# ── export the song as-is ───────────────────────────────────────────────────

def test_as_is_export_produces_a_file_named_after_the_project(project):
    ok = project.fns.export_song_as_is()
    assert ok is True
    assert (project.tmp_path / "out" / "Song.mp3").exists()


def test_as_is_export_does_not_touch_routing(project):
    """The whole point is the mix exactly as it stands."""
    before = project.rmock.mixer_state()
    project.fns.export_song_as_is()
    after = project.rmock.mixer_state()

    for i in range(1, len(before) + 1):
        for field in ("pan", "mute", "solo", "vol"):
            assert before[i][field] == after[i][field]


def test_batch_export_runs_the_as_is_pass_first(project):
    project.md["export_song_as_is"] = True
    make_preset(project, "One")
    make_preset(project, "Two")

    assert project.fns.batch_export() is True

    patterns = [r["pattern"] for r in renders(project)]
    assert patterns[0] == "Song", "as-is render did not run first: %s" % patterns
    assert len(patterns) == 3


def test_batch_export_skips_the_as_is_pass_when_unchecked(project):
    project.md["export_song_as_is"] = False
    make_preset(project, "One")

    project.fns.batch_export()
    assert [r["pattern"] for r in renders(project)] == ["Song-One"]


def test_as_is_pass_can_run_with_no_presets(project):
    """Ticking the box is a reason to export even with an empty preset list."""
    project.md["export_song_as_is"] = True
    assert project.fns.batch_export() is True
    assert (project.tmp_path / "out" / "Song.mp3").exists()


def test_batch_export_reports_a_failed_as_is_pass(project):
    project.md["export_song_as_is"] = True
    make_preset(project, "One")
    project.rmock["render_hook"] = lambda rmock: None  # produces no file

    assert project.fns.batch_export() is False


def test_as_is_setting_persists(project):
    project.md["export_song_as_is"] = True
    project.fns.save_config("global")
    project.reload()
    assert project.md["export_song_as_is"] is True


def test_as_is_export_lands_beside_the_preset_folders(project):
    """It is not a preset, so it does not get a preset subfolder."""
    project.md["export_song_as_is"] = True
    make_preset(project, "One")
    project.fns.batch_export()

    out = project.tmp_path / "out"
    assert (out / "Song.mp3").exists()
    assert (out / "One" / "Song-One.mp3").exists()
