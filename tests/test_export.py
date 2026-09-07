"""Export has to leave the project exactly as it found it — including when
something throws partway through — and has to report honestly."""
import pathlib

import pytest


def render_writes_output(mixdeck, extension="mp3"):
    """Simulate Reaper's renderer actually producing a file."""

    def hook(rmock):
        folder = rmock["project_info_str"]["RENDER_FILE"]
        pattern = rmock["project_info_str"]["RENDER_PATTERN"]
        out = pathlib.Path(folder) / ("%s.%s" % (pattern, extension))
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"fake audio")

    mixdeck.rmock["render_hook"] = hook


def render_does_nothing(mixdeck):
    mixdeck.rmock["render_hook"] = lambda rmock: None


def make_preset(mixdeck, name="Bass Isolated", routing=None):
    mixdeck.fns.create_preset(name, "global")
    preset = mixdeck.fns.get_preset(name)
    for key, channel in (routing or {"<ROOT> > Bass": "L"}).items():
        mixdeck.fns.update_preset_routing(name, key, channel)
    return mixdeck.fns.get_preset(name)


@pytest.fixture
def project(mixdeck):
    mixdeck.add_track("Bass")
    mixdeck.add_track("Gtr")
    mixdeck.add_track("Vox")
    mixdeck.md["global_export_path"] = str(mixdeck.tmp_path / "out").replace("\\", "/")
    return mixdeck


def test_export_restores_mixer_state(project):
    render_writes_output(project)
    before = project.rmock.mixer_state()
    preset = make_preset(project)

    assert project.fns.export_preset(preset) is True

    after = project.rmock.mixer_state()
    for i in range(1, len(before) + 1):
        for field in ("pan", "mute", "solo", "vol"):
            assert before[i][field] == after[i][field], (
                "%s.%s not restored after export" % (before[i]["name"], field)
            )


def test_export_restores_mixer_state_when_render_throws(project):
    """A crash mid-export used to leave every track panned hard and muted."""

    def explode(rmock):
        raise RuntimeError("render blew up")

    project.rmock["render_hook"] = explode
    before = project.rmock.mixer_state()
    preset = make_preset(project)

    ok, err = project.fns.export_preset(preset)

    assert ok is False, "a failed render must be reported as a failure"
    after = project.rmock.mixer_state()
    for i in range(1, len(before) + 1):
        for field in ("pan", "mute", "solo", "vol"):
            assert before[i][field] == after[i][field], (
                "%s.%s left modified after a failed export" % (before[i]["name"], field)
            )


def test_export_restores_render_settings_when_render_throws(project):
    project.rmock["project_info_str"]["RENDER_PATTERN"] = "$project"
    project.rmock["project_info_str"]["RENDER_FILE"] = "C:/PreExisting"

    def explode(rmock):
        raise RuntimeError("render blew up")

    project.rmock["render_hook"] = explode
    project.fns.export_preset(make_preset(project))

    assert project.rmock["project_info_str"]["RENDER_PATTERN"] == "$project"
    assert project.rmock["project_info_str"]["RENDER_FILE"] == "C:/PreExisting"


def test_export_reports_failure_when_no_file_appears(project):
    render_does_nothing(project)
    ok, err = project.fns.export_preset(make_preset(project))
    assert ok is False, "export claimed success but produced no file"
    assert err and "output" in str(err).lower()


def test_batch_export_reports_failures(project):
    render_does_nothing(project)
    make_preset(project, "One")
    make_preset(project, "Two")

    ok = project.fns.batch_export()
    assert ok is False, "batch_export reported success with zero files rendered"


def test_batch_export_reports_success_when_files_appear(project):
    render_writes_output(project)
    make_preset(project, "One")
    make_preset(project, "Two")

    assert project.fns.batch_export() is True


def test_export_wraps_changes_in_an_undo_block(project):
    render_writes_output(project)
    project.fns.export_preset(make_preset(project))
    assert project.rmock["undo_depth"] == 0, "undo block left unbalanced"
    assert "MixDeck" in str(project.rmock["last_undo_name"])
