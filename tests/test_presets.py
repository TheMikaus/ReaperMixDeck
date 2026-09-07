"""Preset CRUD, routing removal, and ordering."""
import pytest


def test_remove_track_from_preset(mixdeck):
    """The Delete button next to a missing track. Used to throw on a
    forward-referenced local and silently do nothing."""
    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.update_preset_routing("Bass", "<ROOT> > Gone", "L")
    assert mixdeck.fns.get_preset("Bass")["routing"]["<ROOT> > Gone"] == "L"

    assert mixdeck.fns.remove_track_from_preset("Bass", "<ROOT> > Gone") is True
    assert mixdeck.fns.get_preset("Bass")["routing"]["<ROOT> > Gone"] is None


def test_remove_track_from_preset_is_case_insensitive(mixdeck):
    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.update_preset_routing("Bass", "<ROOT> > Gone", "L")
    assert mixdeck.fns.remove_track_from_preset("Bass", "<root> > gone") is True


def test_remove_track_from_preset_persists(mixdeck):
    mixdeck.fns.create_preset("Bass", "global")
    mixdeck.fns.update_preset_routing("Bass", "<ROOT> > Gone", "L")
    mixdeck.fns.remove_track_from_preset("Bass", "<ROOT> > Gone")

    mixdeck.reload()
    assert mixdeck.fns.get_preset("Bass")["routing"]["<ROOT> > Gone"] is None


def test_remove_unknown_track_reports_false(mixdeck):
    mixdeck.fns.create_preset("Bass", "global")
    assert mixdeck.fns.remove_track_from_preset("Bass", "<ROOT> > Nope") is False


def test_reorder_survives_a_reload(mixdeck):
    """Drag-to-reorder used to rewrite the merged view and save the untouched
    source lists, so the new order vanished on the next load."""
    for name in ("A", "B", "C"):
        mixdeck.fns.create_preset(name, "global")
    assert mixdeck.preset_names() == ["A", "B", "C"]

    assert mixdeck.fns.reorder_preset("C", 1) is True
    assert mixdeck.preset_names() == ["C", "A", "B"]

    mixdeck.reload()
    assert mixdeck.preset_names() == ["C", "A", "B"], "reorder was not persisted"


def test_reorder_rejects_out_of_range(mixdeck):
    mixdeck.fns.create_preset("A", "global")
    assert mixdeck.fns.reorder_preset("A", 0) is False
    assert mixdeck.fns.reorder_preset("A", 99) is False


def test_reorder_within_project_scope(mixdeck):
    mixdeck.fns.create_preset("G1", "global")
    mixdeck.fns.create_preset("P1", "project")
    mixdeck.fns.create_preset("P2", "project")

    assert mixdeck.fns.reorder_preset("P2", 2) is True
    mixdeck.reload()
    assert mixdeck.preset_names() == ["G1", "P2", "P1"]


def test_default_state_handles_duplicate_track_names(mixdeck):
    """Two tracks called "Gtr" under different parents are routine; keying the
    snapshot by bare name collapsed them into one."""
    mixdeck.add_track("Rhythm", depth=0)
    mixdeck.add_track("Gtr", depth=1, pan=-1.0)
    mixdeck.add_track("Lead", depth=0)
    mixdeck.add_track("Gtr", depth=1, pan=1.0)

    assert mixdeck.fns.save_default_state() is True
    _, count = mixdeck.fns.get_default_state_status()
    assert count == 4, "duplicate names collapsed in the default-state snapshot"

    for track in mixdeck.rmock["tracks"].values():
        track["pan"] = 0.0
    assert mixdeck.fns.restore_default_state() is True

    pans = [t["pan"] for t in mixdeck.rmock["tracks"].values()]
    assert pans == [0.0, -1.0, 0.0, 1.0], "duplicate-named tracks restored to the wrong pan"
