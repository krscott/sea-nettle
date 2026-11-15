# R-PAIR-2, R-PAIR-6: setup's configuration edits add and enable, keep stored keys, and
# report conflicts instead of overwriting.
from __future__ import annotations

import copy
import json
from dataclasses import replace

from sea_nettle.edits import (
    Change,
    EntryWant,
    JsonObject,
    LibraryMappingWant,
    SignedIn,
    UserMappingWant,
    entry,
    grant,
    keep_stored_keys,
    library_mapping,
    switch_on,
    user_mapping,
)
from sea_nettle.model import KEPT_API_KEY, as_list, as_object
from sea_nettle.report import Attention
from sea_nettle.setup import whitelist_items

SOURCE_ID = "5c1b0c32d7d24fb2a8d1a7c09c8a4f11"
STORED_KEY = "enc:v1:CfDJ8secretciphertext"
TOKEN = "fresh-token-secret"
LOCAL_LIBRARY = "aaaabbbbccccddddeeeeffff00001111"

WANT = EntryWant(
    peer="the source",
    url="https://source",
    server_id=SOURCE_ID,
    mode="Pull",
    allow_linking=False,
    fallback_user=None,
)
SIGNED_IN = SignedIn(
    token=TOKEN,
    user="replica-sync",
    user_id="0f6e2d1c4b3a4a598e7d6c5b4a392817",
    administrator=True,
    can_download=True,
    server_name="source",
    server_id=SOURCE_ID,
)
MOVIES = LibraryMappingWant(
    library="Movies",
    source_library_id="11112222333344445555666677778888",
    source_library_name="Movies",
    source_path="/srv/media/movies",
    local_library_id=LOCAL_LIBRARY,
    local_library_name="Movies",
    local_path="/var/lib/jellyfin/replica/movies",
    whitelist=None,
    complete=True,
)


def config(**entry_fields: object) -> JsonObject:
    """A document with an entry for the source, as Server Sync returns it."""
    stored: JsonObject = {
        "Key": "e1",
        "Url": "https://source",
        "ApiKey": STORED_KEY,
        "ServerId": SOURCE_ID.upper(),
        "Mode": "Pull",
        "IsEnabled": True,
        "LibraryMappings": [],
        "UserMappings": None,
    }
    stored.update(entry_fields)
    return {"Servers": [stored], "PeerCallerGrants": [], "LastRunFailures": 3}


def changes(items: list[Change | Attention]) -> list[str]:
    return [i.text for i in items if isinstance(i, Change)]


def codes(items: list[Change | Attention]) -> list[str]:
    return [i.code for i in items if isinstance(i, Attention)]


def servers(doc: JsonObject) -> list[JsonObject]:
    return [as_object(s) for s in as_list(doc["Servers"])]


def mappings(doc: JsonObject) -> list[JsonObject]:
    return [as_object(m) for m in as_list(servers(doc)[0]["LibraryMappings"])]


def test_stored_keys_become_the_kept_placeholder() -> None:
    doc = config()
    keep_stored_keys(doc)
    assert servers(doc)[0]["ApiKey"] == KEPT_API_KEY
    assert STORED_KEY not in json.dumps(doc)


def test_adds_a_missing_entry_with_the_new_token() -> None:
    doc: JsonObject = {"Servers": None}
    items = entry(WANT, SIGNED_IN)(doc)
    assert changes(items) == [
        "Added the source at https://source as a Pull peer, signed in as replica-sync"
    ]
    [added] = servers(doc)
    assert added["ApiKey"] == TOKEN
    assert added["AccessLevel"] == "Administrator"
    assert added["ServerId"] == SOURCE_ID
    # The token stays out of reports and reprs.
    assert TOKEN not in repr(SIGNED_IN) and TOKEN not in repr(items)


def test_keeps_an_existing_entry_matched_by_server_id() -> None:
    doc = config(Url="https://source/", LinkFallbackUserId="x")
    before = copy.deepcopy(doc)
    # No sign-in happens for an existing entry; the edit leaves it as it is.
    assert entry(WANT, None)(doc) == []
    assert doc == before


def test_reports_existing_entries_that_differ() -> None:
    doc = config(Url="https://old-source", IsEnabled=False, Mode="Push")
    before = copy.deepcopy(doc)
    items = entry(WANT, SIGNED_IN)(doc)
    assert codes(items) == ["conflict-entry-url", "conflict-entry-disabled", "conflict-entry-mode"]
    assert doc == before


def test_push_entry_for_a_limited_key_needs_linking_and_its_fallback_user() -> None:
    want = EntryWant(
        peer="the replica",
        url="https://source",
        server_id=SOURCE_ID,
        mode="Push",
        allow_linking=True,
        fallback_user=("0f6e2d1c-4b3a-4a59-8e7d-6c5b4a392817", "replica-sync"),
    )
    assert codes(entry(want, None)(config(Mode="Sync"))) == [
        "conflict-entry-linking",
        "conflict-entry-fallback",
    ]
    ok = config(
        Mode="Push", AllowLinking=True, LinkFallbackUserId="0f6e2d1c4b3a4a598e7d6c5b4a392817"
    )
    assert entry(want, None)(ok) == []


def test_grant_is_added_once() -> None:
    doc: JsonObject = {"PeerCallerGrants": None}
    edit = grant(user_id="0F6E2D1C-4B3A-4A59-8E7D-6C5B4A392817", user_name="source-sync")
    assert changes(edit(doc)) == ["Allowed source-sync to call this server's Server Sync"]
    doc["PeerCallerGrants"] = [
        {"UserId": "0f6e2d1c4b3a4a598e7d6c5b4a392817", "UserName": "source-sync", "Locations": []}
    ]
    assert edit(doc) == []
    doc["PeerCallerGrants"] = [
        {"UserId": "0f6e2d1c4b3a4a598e7d6c5b4a392817", "Locations": ["10.0.0.0/8"]}
    ]
    assert codes(edit(doc)) == ["conflict-grant-locations"]


def test_mapping_is_created_disabled_until_enabled() -> None:
    doc = config()
    assert changes(library_mapping(SOURCE_ID, MOVIES, enable=False)(doc)) == [
        "Mapped Movies to the replica as links (disabled)"
    ]
    [mapping] = mappings(doc)
    assert mapping["IsEnabled"] is False and mapping["StorageMode"] == "Link"
    assert mapping["FilterMode"] == "AllowAll"
    # A rerun before the link check passes changes nothing.
    assert library_mapping(SOURCE_ID, MOVIES, enable=False)(doc) == []
    assert changes(library_mapping(SOURCE_ID, MOVIES, enable=True)(doc)) == [
        "Enabled the mapping for Movies"
    ]
    assert mapping["IsEnabled"] is True
    assert library_mapping(SOURCE_ID, MOVIES, enable=True)(doc) == []


def test_mapping_with_missing_whitelist_items_stays_disabled() -> None:
    want = replace(MOVIES, whitelist=(), complete=False)
    doc = config()
    library_mapping(SOURCE_ID, want, enable=True)(doc)
    [mapping] = mappings(doc)
    assert mapping["IsEnabled"] is False and mapping["FilterMode"] == "Whitelist"


def test_whitelist_keeps_dashboard_items_and_adds_the_spec_items() -> None:
    dashboard_item = {"ItemId": "d1", "Name": "Sintel", "Path": "/srv/media/movies/Sintel"}
    spec_item: JsonObject = {
        "ItemId": "b1",
        "Name": "Big Buck Bunny",
        "Path": "/srv/media/movies/BBB",
    }
    existing = {
        "SourceRootPath": "/srv/media/movies/",
        "LocalLibraryId": LOCAL_LIBRARY,
        "StorageMode": "Link",
        "FilterMode": "Whitelist",
        "FilteredItems": [dashboard_item],
        "IsEnabled": True,
    }
    doc = config(LibraryMappings=[existing])
    want = replace(MOVIES, whitelist=(spec_item,))
    assert changes(library_mapping(SOURCE_ID, want, enable=True)(doc)) == [
        "Added Big Buck Bunny to the whitelist of Movies"
    ]
    assert existing["FilteredItems"] == [dashboard_item, spec_item]


def test_reports_mappings_that_differ() -> None:
    copy_mapping = {
        "SourceRootPath": "/srv/media/movies",
        "LocalLibraryId": LOCAL_LIBRARY,
        "IsEnabled": False,
    }
    other_source = {"SourceRootPath": "/srv/media/other", "LocalLibraryId": LOCAL_LIBRARY}
    filtered = {**copy_mapping, "StorageMode": "Link", "FilterMode": "Blacklist"}
    for existing in [copy_mapping, other_source, filtered]:
        doc = config(LibraryMappings=[existing])
        before = copy.deepcopy(doc)
        items = library_mapping(SOURCE_ID, MOVIES, enable=True)(doc)
        assert codes(items) and not changes(items), items
        assert doc == before


def test_edits_for_a_missing_entry_do_nothing() -> None:
    doc: JsonObject = {"Servers": []}
    assert library_mapping(SOURCE_ID, MOVIES, enable=True)(doc) == []


def test_user_mapping() -> None:
    want = UserMappingWant(
        source_user_id="9a8b7c6d-5e4f-4031-2a1b-2c3d4e5f6071",
        source_name="alice",
        local_user_id="11112222333344445555666677778888",
        local_name="alice",
    )
    doc = config()
    assert changes(user_mapping(SOURCE_ID, want, enable=False)(doc)) == [
        "Mapped user alice to the source (disabled)"
    ]
    assert changes(user_mapping(SOURCE_ID, want, enable=True)(doc)) == [
        "Enabled the user mapping for alice"
    ]
    other = replace(want, source_user_id="ffff")
    assert codes(user_mapping(SOURCE_ID, other, enable=True)(doc)) == ["conflict-user-mapping"]


def test_switch_on() -> None:
    doc: JsonObject = {"EnableContentSync": False}
    assert changes(switch_on("EnableContentSync", "content sync")(doc)) == [
        "Turned on content sync"
    ]
    assert switch_on("EnableContentSync", "content sync")(doc) == []


def test_whitelist_paths_match_items_or_their_folders() -> None:
    items: list[JsonObject] = [
        {"Id": "m1", "Name": "Clip", "Year": 2020, "Path": "/m/Clip (2020)/Clip (2020).mp4"},
        {"Id": "s1", "Name": "Show", "Path": "/m/Show/"},
        {"Id": "m2", "Name": "Clipper", "Path": "/m/Clip (2020) extra/x.mp4"},
    ]
    filtered, missing = whitelist_items(items, ("/m/Clip (2020)", "/m/Show", "/m/Gone"))
    assert [i["ItemId"] for i in filtered] == ["m1", "s1"]
    assert filtered[1]["Path"] == "/m/Show"
    assert missing == ["/m/Gone"]
