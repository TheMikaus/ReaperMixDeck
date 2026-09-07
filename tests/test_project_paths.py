"""Project name/folder derivation drives both the config filename and the
exported filename, so a truncated name silently misfiles everything."""
import pytest

CASES = [
    ("C:/Music/Song.rpp", "Song"),
    ("C:/Music/My.Song.rpp", "My.Song"),
    ("C:/Music/Take 2 - final.rpp", "Take 2 - final"),
    ("C:\\Music\\Backslash.rpp", "Backslash"),
    ("C:/Music/no_extension", "no_extension"),
]


@pytest.mark.parametrize("path,expected", CASES)
def test_project_name(mixdeck, path, expected):
    mixdeck.rmock.set_project(path)
    assert mixdeck.fns.get_project_name() == expected


def test_unsaved_project_has_no_name(mixdeck):
    mixdeck.rmock.set_project("")
    assert mixdeck.fns.get_project_name() is None


def test_export_refuses_an_unsaved_project(mixdeck):
    mixdeck.rmock.set_project("")
    mixdeck.fns.create_preset("Bass", "global")
    ok, err = mixdeck.fns.export_preset(mixdeck.fns.get_preset("Bass"))
    assert ok is False
    assert "saved" in str(err).lower()
