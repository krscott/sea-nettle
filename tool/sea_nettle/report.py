"""The `status` report: what needs attention, and how to fix it (R-PAIR-4)."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass

from .model import Entry, LinkCheck, Plugin, User, normalize_id, same_id

SERVERS = "Dashboard > Server Sync > Servers"
WHITELIST = "Dashboard > Server Sync > Settings > Whitelist"
RERUN = "then run `sea-nettle status` again"


@dataclass(kw_only=True, frozen=True)
class Snapshot:
    """Everything `status` reads from this server."""

    server_name: str
    plugin: Plugin | None
    entries: tuple[Entry, ...]
    users: tuple[User, ...]
    library_ids: frozenset[str]
    # Link checks by entry key, for the entries that `checked_entries` selects.
    checks: dict[str, LinkCheck]


@dataclass(kw_only=True, frozen=True)
class Attention:
    code: str
    subject: str
    problem: str
    fix: str


@dataclass(kw_only=True, frozen=True)
class Peer:
    name: str
    url: str
    # Server Sync's link check message, or why there is none.
    link: str


@dataclass(kw_only=True, frozen=True)
class Report:
    server: str
    peers: tuple[Peer, ...]
    attention: tuple[Attention, ...]

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    def to_text(self) -> str:
        lines = [f"Server Sync on {self.server}"]
        lines += [f"  Peer {p.name} at {p.url}: {p.link}" for p in self.peers]
        if not self.attention:
            lines.append("Nothing needs attention.")
            return "\n".join(lines) + "\n"
        lines.append("Needs attention:")
        for item in self.attention:
            lines.append(f"- {item.subject}: {item.problem}")
            lines.append(f"  Fix: {item.fix}")
        return "\n".join(lines) + "\n"


def checked_entries(entries: tuple[Entry, ...]) -> tuple[Entry, ...]:
    """Entries the link check can run for: enabled, with a URL and a key."""
    return tuple(e for e in entries if e.enabled and e.url and e.has_api_key)


def build(snapshot: Snapshot, *, expected_version: str) -> Report:
    return Report(
        server=snapshot.server_name,
        peers=tuple(_peer(e, snapshot.checks.get(e.key)) for e in snapshot.entries),
        attention=tuple(assess(snapshot, expected_version=expected_version)),
    )


def _peer(entry: Entry, check: LinkCheck | None) -> Peer:
    if check is not None:
        link = check.message
    elif not entry.enabled:
        link = "disabled, not checked"
    else:
        link = "not checked"
    return Peer(name=entry.name, url=entry.url, link=link)


def assess(snapshot: Snapshot, *, expected_version: str) -> list[Attention]:
    plugin = plugin_attention(snapshot.plugin, expected_version=expected_version)
    # Without an active Server Sync there is no configuration to assess.
    if snapshot.plugin is None or snapshot.plugin.status != "Active":
        return plugin
    items = plugin
    if not snapshot.entries:
        items.append(
            Attention(
                code="no-peers",
                subject="Server Sync",
                problem="it has no peer entries.",
                fix=f"Add the other server under {SERVERS}, as described under "
                '"Dashboard setup" in sea-nettle\'s nix/modules/README.md.',
            )
        )
    items += duplicate_server_ids(snapshot.entries)
    for entry in snapshot.entries:
        items += entry_attention(entry, snapshot.checks.get(entry.key))
        items += mapping_attention(entry, snapshot.users, snapshot.library_ids)
    items += unmapped_users(snapshot.entries, snapshot.users)
    return items


def plugin_attention(plugin: Plugin | None, *, expected_version: str) -> list[Attention]:
    if plugin is None:
        return [
            Attention(
                code="server-sync-missing",
                subject="Server Sync",
                problem="the plugin is not installed.",
                fix="Import sea-nettle's server-sync module (replica includes it), "
                "rebuild, and restart jellyfin.service.",
            )
        ]
    items: list[Attention] = []
    if plugin.status != "Active":
        items.append(
            Attention(
                code="server-sync-inactive",
                subject="Server Sync",
                problem=f"the plugin is {plugin.status}.",
                fix="Enable it under Dashboard > Plugins, restart jellyfin.service, "
                "and check its journal if it does not become Active.",
            )
        )
    if plugin.version != expected_version:
        items.append(
            Attention(
                code="server-sync-version",
                subject="Server Sync",
                problem=f"Jellyfin runs version {plugin.version}, "
                f"but this system pins {expected_version}.",
                fix="Restart jellyfin.service, which installs the pinned version.",
            )
        )
    return items


def duplicate_server_ids(entries: tuple[Entry, ...]) -> list[Attention]:
    """Server Sync matches callers by server ID and only ever uses the first entry."""
    items: list[Attention] = []
    first: dict[str, Entry] = {}
    for entry in entries:
        server_id = normalize_id(entry.server_id)
        if not server_id:
            continue
        if server_id not in first:
            first[server_id] = entry
            continue
        items.append(
            Attention(
                code="entry-duplicate-server-id",
                subject=f"Peer {entry.name}",
                problem=f"it records the same server ID as {first[server_id].name}, "
                "so Server Sync never uses it.",
                fix=f"Delete one of the two entries under {SERVERS}.",
            )
        )
    return items


def entry_attention(entry: Entry, check: LinkCheck | None) -> list[Attention]:
    subject = f"Peer {entry.name}"
    if not entry.enabled:
        return []
    if not entry.url or not entry.has_api_key:
        return [
            Attention(
                code="entry-incomplete",
                subject=subject,
                problem="its entry has no URL or no key, so Server Sync skips it.",
                fix=f"Open the entry under {SERVERS}, enter the URL, and sign in.",
            )
        ]
    items: list[Attention] = []
    if not entry.server_id:
        items.append(
            Attention(
                code="entry-no-server-id",
                subject=subject,
                problem="its entry records no server ID, so the peer cannot pair "
                "with this server or send it changes.",
                fix=f"Open the entry under {SERVERS} and sign in again, "
                f"which records the ID; {RERUN}.",
            )
        )
    elif check is not None and check.server_id and not same_id(check.server_id, entry.server_id):
        items.append(
            Attention(
                code="entry-server-id-mismatch",
                subject=subject,
                problem=f"its entry records server ID {entry.server_id}, but the server "
                f"at {entry.url} reports {check.server_id}.",
                fix=f"If {entry.url} is the right server, open the entry under {SERVERS} "
                f"and sign in again; otherwise correct the URL; {RERUN}.",
            )
        )
    if check is not None:
        items += link_attention(entry, check)
    return items


def link_attention(entry: Entry, check: LinkCheck) -> list[Attention]:
    """At most one item: the first problem in the order the link check meets them."""
    subject = f"Peer {entry.name}"
    if not check.reachable:
        return [
            Attention(
                code="peer-unreachable",
                subject=subject,
                problem=f"the link check could not reach it: {check.message}",
                fix=f"Check that Jellyfin runs there and that this host can open {entry.url}; "
                f"{RERUN}.",
            )
        ]
    if check.peer_mode is None:
        return [
            Attention(
                code="peer-not-listed",
                subject=subject,
                problem=f"it does not list this server, or refused to say: {check.message}",
                fix=f"On {entry.name}, add this server under {SERVERS} and sign in from "
                f"that entry. On each server, allow the other's key user under {WHITELIST} "
                "with no locations: peer calls reach Jellyfin through the local proxy, "
                "so they come from 127.0.0.1. Then run `sea-nettle status` again.",
            )
        ]
    if not check.paired:
        reason = check.pairing_error or "no reason was given"
        return [
            Attention(
                code="peer-unpaired",
                subject=subject,
                problem=f"it could not pair with this server: {reason}",
                fix=f"Fix the cause on the server it names, and keep {entry.name}'s entry for "
                f"this server enabled; {RERUN}, which pairs again.",
            )
        ]
    if check.severity != "ok":
        return [
            Attention(
                code="peer-link-warning",
                subject=subject,
                problem=f"the link check warns: {check.message}",
                fix=f"Follow the link check's advice; {RERUN}.",
            )
        ]
    return []


def mapping_attention(
    entry: Entry, users: tuple[User, ...], library_ids: frozenset[str]
) -> list[Attention]:
    if not entry.enabled:
        return []
    subject = f"Peer {entry.name}"
    user_ids = {normalize_id(u.id) for u in users}
    items: list[Attention] = []
    for library in entry.library_mappings:
        if normalize_id(library.local_id) not in library_ids:
            items.append(
                Attention(
                    code="mapping-missing-library",
                    subject=subject,
                    problem=f"it maps {library.source_name} to the local library "
                    f"{library.local_name}, which no longer exists.",
                    fix=f"Under {SERVERS}, map {library.source_name} to an existing "
                    "library or remove the mapping.",
                )
            )
    for user in entry.user_mappings:
        if normalize_id(user.local_id) not in user_ids:
            items.append(
                Attention(
                    code="mapping-missing-user",
                    subject=subject,
                    problem=f"it maps {user.source_name} to the local user "
                    f"{user.local_name}, who no longer exists.",
                    fix=f"Under {SERVERS}, step 4 Users, remove the mapping or map "
                    f"{user.source_name} to an existing user.",
                )
            )
        elif user.enabled and skips_user(entry, user.source_id):
            items.append(
                Attention(
                    code="user-mapping-skipped",
                    subject=subject,
                    problem=f"it maps {user.source_name} to {user.local_name}, but its key "
                    f"belongs to the standard user {entry.authenticated_user}, so Server "
                    "Sync syncs only that user's history and settings.",
                    fix=f"Sign in from the entry under {SERVERS} with an administrator "
                    "on that server, or remove the mapping.",
                )
            )
    return items


def skips_user(entry: Entry, source_user_id: str) -> bool:
    """Server Sync's `SourceServer.MaySyncUser`, negated."""
    if entry.access_level.lower() != "user":
        return False
    if not _is_guid(entry.authenticated_user_id):
        return False
    return not (_is_guid(source_user_id) and same_id(source_user_id, entry.authenticated_user_id))


def _is_guid(value: str) -> bool:
    digits = normalize_id(value)
    return len(digits) == 32 and all(c in "0123456789abcdef" for c in digits)


def unmapped_users(entries: tuple[Entry, ...], users: tuple[User, ...]) -> list[Attention]:
    """Peer Login creates replica users on first sign-in; mapping them is a later step."""
    mapped = {
        normalize_id(m.local_id) for e in entries if e.enabled for m in e.user_mappings if m.enabled
    }
    return [
        Attention(
            code="unmapped-user",
            subject=f"User {user.name}",
            problem="this Peer Login user has no user mapping, so their watch history "
            "and settings do not sync.",
            fix=f"Under {SERVERS}, open the source's entry and map {user.name} to "
            "their source user in step 4 Users.",
        )
        for user in users
        if user.peer_login and normalize_id(user.id) not in mapped
    ]
