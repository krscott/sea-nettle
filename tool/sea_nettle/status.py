"""`sea-nettle status`: reads this server's Server Sync setup and runs its link checks.

Apart from its own session, every call reads, except Server Sync's link check, which can
renew pairing secrets but never changes configuration (R-PAIR-1).
"""

from __future__ import annotations

from .jellyfin import Fatal, HttpStatus, Jellyfin
from .model import (
    KEPT_API_KEY,
    SERVER_SYNC_ID,
    Entry,
    LinkCheck,
    Plugin,
    User,
    as_list,
    as_object,
    normalize_id,
    text,
)
from .report import Snapshot, checked_entries

# The link check makes several calls to the peer, and the peer calls this server back.
# A check still open after this long reports the peer as unreachable.
CHECK_TIMEOUT = 300


def collect(api: Jellyfin) -> Snapshot:
    info = as_object(api.get("/System/Info"))
    plugin = Plugin.find(api.get("/Plugins"), SERVER_SYNC_ID)
    entries: tuple[Entry, ...] = ()
    checks: dict[str, LinkCheck] = {}
    if plugin is not None and plugin.status == "Active":
        entries = Entry.list_from_config(api.get(f"/Plugins/{SERVER_SYNC_ID}/Configuration"))
        checks = {e.key: check_link(api, e) for e in checked_entries(entries)}
    return Snapshot(
        server_name=text(info, "ServerName"),
        plugin=plugin,
        entries=entries,
        users=tuple(User.from_json(u) for u in as_list(api.get("/Users"))),
        library_ids=frozenset(
            normalize_id(text(as_object(f), "ItemId"))
            for f in as_list(api.get("/Library/VirtualFolders"))
        ),
        checks=checks,
    )


def check_link(api: Jellyfin, entry: Entry) -> LinkCheck:
    """Server Sync's own link check, run as the dashboard's Check Link button runs it.

    The kept-key placeholder makes Server Sync use the key it stores for the entry with
    this key, and only at its saved URL, so this command never handles the key.
    """
    try:
        answer = api.request(
            "POST",
            "/Sync/Hints/CheckPeer",
            {
                "ServerUrl": entry.url,
                "ApiKey": KEPT_API_KEY,
                "ServerKey": entry.key,
                "AllowPrivateNetwork": entry.allow_private_network,
                "Mode": entry.mode,
            },
            timeout=CHECK_TIMEOUT,
        )
    except HttpStatus:
        # Server Sync reports the peer's problems in its answer, so this one is local.
        raise
    except Fatal as e:
        # A peer that accepts connections but never answers keeps the check open.
        return LinkCheck.unanswered(f"no answer within {CHECK_TIMEOUT // 60} minutes ({e})")
    return LinkCheck.from_json(answer)
