# R-PAIR-3: setup ends a peer session whose token it does not keep, and keeps one it saved.
from __future__ import annotations

import copy
from pathlib import Path

import pytest
from test_jellyfin import Stub, stub
from test_spec import SPEC

from sea_nettle.edits import EntryWant, JsonObject, SignedIn
from sea_nettle.jellyfin import Jellyfin
from sea_nettle.model import as_object
from sea_nettle.setup import CONFIG, Run
from sea_nettle.spec import Spec, parse

__all__ = ["stub"]

SOURCE_ID = "5c1b0c32d7d24fb2a8d1a7c09c8a4f11"


class Local(Jellyfin):
    """This server's Jellyfin: holds Server Sync's document; a save is interrupted."""

    def __init__(self, *, save_first: bool) -> None:
        super().__init__("http://local")
        self.config: JsonObject = {"Servers": []}
        self.save_first = save_first

    def request(
        self, method: str, path: str, body: object = None, *, timeout: float = 30
    ) -> object:
        assert path == CONFIG, path
        if method == "GET":
            return copy.deepcopy(self.config)
        if self.save_first:
            self.config = as_object(body)
        # Ctrl-C while Jellyfin answers.
        raise KeyboardInterrupt


def interrupted_entry(peer_url: str, *, save_first: bool) -> None:
    value = copy.deepcopy(SPEC)
    as_object(value["source"])["url"] = peer_url
    spec = parse(value, role="replica", admin_name="admin")
    assert isinstance(spec, Spec), spec
    run = Run(Local(save_first=save_first), spec, role="replica", replica_root=Path("/r"))
    signed_in = SignedIn(
        token="peer-token",
        user="replica-sync",
        user_id="u1",
        administrator=True,
        can_download=True,
        server_name="source",
        server_id=SOURCE_ID,
    )
    run.sign_in_to_peer = lambda server_id: signed_in  # type: ignore[method-assign]
    want = EntryWant(
        peer="the source",
        url=peer_url,
        server_id=SOURCE_ID,
        mode="Pull",
        allow_linking=False,
        account="replica-sync",
        administrator=True,
        fallback_user=None,
    )
    with pytest.raises(KeyboardInterrupt):
        run.ensure_entry(want)


def test_interrupted_save_ends_the_unsaved_peer_session(stub: tuple[Stub, str]) -> None:
    state, url = stub
    state.answers["POST /Sessions/Logout"] = (204, None)
    interrupted_entry(url, save_first=False)
    assert state.calls == ["POST /Sessions/Logout"]


def test_interrupted_save_keeps_the_saved_token(stub: tuple[Stub, str]) -> None:
    state, url = stub
    interrupted_entry(url, save_first=True)
    assert state.calls == []
