# R-PAIR-2, R-PAIR-4: the attention rules, their fixes, and the absence of keys from reports.
from __future__ import annotations

import json
from dataclasses import replace

from sea_nettle.model import Entry, LinkCheck, Plugin, User
from sea_nettle.report import Attention, Report, Snapshot, assess, build, checked_entries

VERSION = "12.2.11.4"
SOURCE_ID = "5c1b0c32d7d24fb2a8d1a7c09c8a4f11"
SYNC_USER_ID = "0f6e2d1c-4b3a-4a59-8e7d-6c5b4a392817"
ALICE_SOURCE_ID = "9a8b7c6d5e4f40312a1b2c3d4e5f6071"
ALICE_LOCAL_ID = "11112222333344445555666677778888"
LIBRARY_ID = "aaaabbbbccccddddeeeeffff00001111"
STORED_KEY = "enc:v1:CfDJ8secretciphertext"


def entry_json(**overrides: object) -> dict[str, object]:
    entry: dict[str, object] = {
        "Key": "e1",
        "Name": "",
        "ServerName": "source",
        "Url": "https://source",
        "ApiKey": STORED_KEY,
        "AllowPrivateNetwork": True,
        "Mode": "Pull",
        "ServerId": SOURCE_ID,
        "IsEnabled": True,
        "AccessLevel": "Administrator",
        "AuthenticatedUser": "replica-sync",
        "AuthenticatedUserId": SYNC_USER_ID,
        "LibraryMappings": [
            {
                "SourceLibraryName": "Movies",
                "LocalLibraryId": LIBRARY_ID,
                "LocalLibraryName": "Replica Movies",
                "IsEnabled": False,
            }
        ],
        "UserMappings": [
            {
                "SourceUserId": ALICE_SOURCE_ID,
                "SourceUserName": "Alice",
                "LocalUserId": ALICE_LOCAL_ID,
                "LocalUserName": "Alice",
                "IsEnabled": True,
            }
        ],
    }
    entry.update(overrides)
    return entry


def entry(**overrides: object) -> Entry:
    return Entry.from_json(entry_json(**overrides))


def ok_check(**overrides: object) -> LinkCheck:
    check: dict[str, object] = {
        "Reachable": True,
        "ServerId": SOURCE_ID,
        "PeerMode": "Push",
        "Paired": True,
        "PairingError": None,
        "Severity": "ok",
        "Message": "Ready.",
    }
    check.update(overrides)
    return LinkCheck.from_json(check)


ALICE = User.from_json(
    {
        "Id": ALICE_LOCAL_ID,
        "Name": "Alice",
        "Policy": {
            "AuthenticationProviderId": "Jellyfin.Plugin.PeerLogin.PeerAuthenticationProvider"
        },
    }
)
ADMIN = User.from_json(
    {
        "Id": "ffffeeeeddddccccbbbbaaaa99998888",
        "Name": "replica-admin",
        "Policy": {
            "AuthenticationProviderId": "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"
        },
    }
)


def snapshot(
    *entries: Entry, checks: dict[str, LinkCheck] | None = None, **overrides: object
) -> Snapshot:
    if not entries:
        entries = (entry(),)
    if checks is None:
        checks = {e.key: ok_check() for e in checked_entries(entries)}
    base = Snapshot(
        server_name="replica",
        plugin=Plugin(version=VERSION, status="Active"),
        entries=entries,
        users=(ALICE, ADMIN),
        library_ids=frozenset({LIBRARY_ID}),
        checks=checks,
    )
    return replace(base, **overrides)  # type: ignore[arg-type]


def codes(s: Snapshot) -> list[str]:
    return [a.code for a in assess(s, expected_version=VERSION)]


def only(s: Snapshot, code: str) -> Attention:
    items = assess(s, expected_version=VERSION)
    assert [a.code for a in items] == [code], items
    item = items[0]
    assert item.problem and item.fix
    return item


def test_healthy_pair_needs_no_attention() -> None:
    report = build(snapshot(), expected_version=VERSION)
    assert report.attention == ()
    assert report.peers[0].name == "source"
    assert "Nothing needs attention." in report.to_text()


def test_server_sync_missing_stops_the_assessment() -> None:
    only(snapshot(plugin=None, entries=()), "server-sync-missing")


def test_server_sync_disabled() -> None:
    only(snapshot(plugin=Plugin(version=VERSION, status="Disabled")), "server-sync-inactive")


def test_server_sync_version_differs_from_pin() -> None:
    item = only(
        snapshot(plugin=Plugin(version="12.2.10.0", status="Active")), "server-sync-version"
    )
    assert "12.2.10.0" in item.problem and VERSION in item.problem


def test_no_peer_entries() -> None:
    only(snapshot(entries=(), checks={}, users=(ADMIN,)), "no-peers")


def test_duplicate_server_ids() -> None:
    first = entry()
    second = entry(Key="e2", Name="source again", ServerId=SOURCE_ID.upper())
    assert codes(snapshot(first, second)) == ["entry-duplicate-server-id"]


def test_entry_without_key_is_incomplete_and_not_checked() -> None:
    incomplete = entry(ApiKey="")
    assert checked_entries((incomplete,)) == ()
    only(snapshot(incomplete), "entry-incomplete")


def test_disabled_entry_is_skipped() -> None:
    disabled = entry(IsEnabled=False, ServerId="")
    assert checked_entries((disabled,)) == ()
    report = build(snapshot(disabled), expected_version=VERSION)
    # No enabled entry streams links, so Alice's missing mapping does not matter yet.
    assert [a.code for a in report.attention] == []
    assert report.peers[0].link == "disabled, not checked"


def test_entry_without_server_id() -> None:
    only(snapshot(entry(ServerId="")), "entry-no-server-id")


def test_entry_server_id_differs_from_peer() -> None:
    other = "0123456789abcdef0123456789abcdef"
    item = only(snapshot(checks={"e1": ok_check(ServerId=other)}), "entry-server-id-mismatch")
    assert other in item.problem


def test_server_id_matches_ignoring_case_only() -> None:
    # Server Sync's FindServerById ignores case but not dashes.
    assert codes(snapshot(checks={"e1": ok_check(ServerId=SOURCE_ID.upper())})) == []
    dashed = "5c1b0c32-d7d2-4fb2-a8d1-a7c09c8a4f11"
    only(snapshot(checks={"e1": ok_check(ServerId=dashed)}), "entry-server-id-mismatch")


def test_unreachable_peer() -> None:
    check = ok_check(Reachable=False, ServerId=None, PeerMode=None, Paired=False, Severity="error")
    item = only(snapshot(checks={"e1": check}), "peer-unreachable")
    assert "https://source" in item.fix


def test_link_check_that_never_answers() -> None:
    check = LinkCheck.unanswered("no answer within 5 minutes (timed out)")
    item = only(snapshot(checks={"e1": check}), "peer-unreachable")
    assert "timed out" in item.problem


def test_peer_that_does_not_list_this_server() -> None:
    check = ok_check(PeerMode=None, Paired=False, Severity="warn", Message="does not list")
    item = only(snapshot(checks={"e1": check}), "peer-not-listed")
    assert "does not list" in item.problem
    assert "Whitelist" in item.fix and "no locations" in item.fix


def test_unpaired_peer() -> None:
    check = ok_check(Paired=False, PairingError="the entry is disabled", Severity="warn")
    item = only(snapshot(checks={"e1": check}), "peer-unpaired")
    assert "the entry is disabled" in item.problem


def test_link_check_warning() -> None:
    check = ok_check(Severity="warn", Message="Its clock is about 5 minutes off.")
    item = only(snapshot(checks={"e1": check}), "peer-link-warning")
    assert "clock" in item.problem


def test_mapping_to_missing_library() -> None:
    only(snapshot(library_ids=frozenset[str]()), "mapping-missing-library")


def test_mapping_to_missing_user() -> None:
    # Alice is mapped but gone; no Peer Login user is left unmapped.
    only(snapshot(users=(ADMIN,)), "mapping-missing-user")


def test_standard_user_key_skips_other_users() -> None:
    standard = entry(AccessLevel="User")
    item = only(snapshot(standard), "user-mapping-skipped")
    assert "replica-sync" in item.problem


def test_standard_user_key_keeps_its_own_user() -> None:
    own = {
        "SourceUserId": SYNC_USER_ID.replace("-", ""),
        "SourceUserName": "replica-sync",
        "LocalUserId": ALICE_LOCAL_ID,
        "LocalUserName": "Alice",
        "IsEnabled": True,
    }
    assert codes(snapshot(entry(AccessLevel="User", UserMappings=[own]))) == []


def test_unmapped_peer_login_user() -> None:
    item = only(snapshot(entry(UserMappings=[])), "unmapped-user")
    assert item.subject == "User Alice"


def test_limited_key_needs_no_user_mappings() -> None:
    # A standard user's key streams only as itself, so the source's fallback user covers
    # every replica user.
    assert codes(snapshot(entry(AccessLevel="User", UserMappings=[]))) == []


def test_disabled_user_mapping_leaves_user_unmapped() -> None:
    disabled: dict[str, object] = {
        "SourceUserId": ALICE_SOURCE_ID,
        "SourceUserName": "Alice",
        "LocalUserId": ALICE_LOCAL_ID,
        "LocalUserName": "Alice",
        "IsEnabled": False,
    }
    assert codes(snapshot(entry(UserMappings=[disabled]))) == ["unmapped-user"]


def test_reports_never_carry_api_keys() -> None:
    parsed = entry()
    assert parsed.has_api_key
    assert STORED_KEY not in repr(parsed)
    report: Report = build(snapshot(parsed), expected_version=VERSION)
    for output in (report.to_text(), report.to_json()):
        assert STORED_KEY not in output
    json.loads(report.to_json())


def test_text_report_lists_problem_and_fix() -> None:
    text = build(snapshot(entry(UserMappings=[])), expected_version=VERSION).to_text()
    assert "Needs attention:" in text
    assert "- User Alice: this Peer Login user has no user mapping" in text
    assert "  Fix: Add Alice to the users of sea-nettle's setup spec" in text
