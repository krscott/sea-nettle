"""Edits to Server Sync's configuration document, as pure functions over its JSON.

`setup` reads the document just before each write and applies these to it, so edits made
since its earlier reads, by the dashboard or by Server Sync's own tasks, are kept. Each
edit only adds or enables; when something it would build on differs from the spec, it
reports a conflict and leaves that part of the document unchanged (R-PAIR-6).
"""

from __future__ import annotations

import posixpath
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field

from .model import KEPT_API_KEY, as_list, as_object, flag, normalize_id, server_id_key, text
from .report import SERVERS, WHITELIST, Attention

JsonObject = dict[str, object]


@dataclass(kw_only=True, frozen=True)
class Change:
    """Something `setup` changed."""

    text: str


Item = Change | Attention
Edit = Callable[[JsonObject], list[Item]]


def keep_stored_keys(config: JsonObject) -> None:
    """Replaces every stored key with Server Sync's kept-key placeholder (R-PAIR-2).

    Server Sync then keeps each entry's key on save, while the entry's `Key` and URL stay
    unchanged, and the document holds no key material.
    """
    for entry in _list(config, "Servers"):
        if text(entry, "ApiKey"):
            entry["ApiKey"] = KEPT_API_KEY


def _list(obj: JsonObject, key: str) -> list[JsonObject]:
    """The objects in a JSON array field, created when null; edits to them stay in `obj`."""
    items = as_list(obj.get(key))
    obj[key] = items
    return [as_object(i) for i in items]


def _append(obj: JsonObject, key: str, item: JsonObject) -> None:
    _list(obj, key)
    as_list(obj[key]).append(item)


def strip_slash(value: str) -> str:
    return value.rstrip("/") or value


def same_url(a: str, b: str) -> bool:
    return a.rstrip("/").lower() == b.rstrip("/").lower()


def find_entry(config: JsonObject, server_id: str) -> JsonObject | None:
    """The entry Server Sync uses for a peer: the first with its server ID (`FindServerById`)."""
    for entry in _list(config, "Servers"):
        if server_id_key(text(entry, "ServerId")) == server_id_key(server_id):
            return entry
    return None


def entry_name(entry: JsonObject) -> str:
    return text(entry, "Name").strip() or text(entry, "ServerName").strip() or text(entry, "Url")


def grant(*, user_id: str, user_name: str) -> Edit:
    """Lets a peer's sync account call this server's Server Sync from any address.

    Peer calls reach Jellyfin through the local HTTPS proxy, so they all come from
    127.0.0.1, and a location cannot tell peers apart.
    """

    def edit(config: JsonObject) -> list[Item]:
        for existing in _list(config, "PeerCallerGrants"):
            if normalize_id(text(existing, "UserId")) != normalize_id(user_id):
                continue
            if as_list(existing.get("Locations")):
                return [
                    Attention(
                        code="conflict-grant-locations",
                        subject=f"User {user_name}",
                        problem="its Server Sync caller grant is limited to locations, but "
                        "peer calls arrive through the local proxy from 127.0.0.1.",
                        fix=f"Under {WHITELIST}, remove the locations from {user_name}'s "
                        "grant, then run `sea-nettle setup` again.",
                    )
                ]
            return []
        _append(
            config, "PeerCallerGrants", {"UserId": user_id, "UserName": user_name, "Locations": []}
        )
        return [Change(text=f"Allowed {user_name} to call this server's Server Sync")]

    return edit


@dataclass(kw_only=True, frozen=True)
class SignedIn:
    """What `/Sync/Authenticate` returned for a peer's sync account."""

    token: str = field(repr=False)
    user: str
    user_id: str
    administrator: bool
    can_download: bool | None
    server_name: str
    server_id: str


@dataclass(kw_only=True, frozen=True)
class EntryWant:
    """The entry this server needs for its peer."""

    peer: str
    url: str
    server_id: str
    mode: str
    allow_linking: bool
    # The peer's sync account that the entry's key belongs to, and whether it is an
    # administrator there.
    account: str
    administrator: bool
    # The user here that link streams run as, when the peer's key is a standard user's.
    fallback_user: tuple[str, str] | None


def entry(want: EntryWant, signed_in: SignedIn | None) -> Edit:
    """Adds the entry when none has the peer's server ID; checks an existing one."""

    def edit(config: JsonObject) -> list[Item]:
        existing = find_entry(config, want.server_id)
        if existing is not None:
            return _entry_conflicts(existing, want)
        if signed_in is None:
            return []
        _append(
            config,
            "Servers",
            {
                "Key": uuid.uuid4().hex,
                "Name": "",
                "Url": want.url,
                "AllowPrivateNetwork": True,
                "ApiKey": signed_in.token,
                "AuthenticatedUser": signed_in.user,
                "AuthenticatedUserId": signed_in.user_id,
                "ServerName": signed_in.server_name,
                "ServerId": signed_in.server_id,
                "AccessLevel": "Administrator" if signed_in.administrator else "User",
                "CanDownload": signed_in.can_download,
                "Mode": want.mode,
                "IsEnabled": True,
                "AllowLinking": want.allow_linking,
                "LinkFallbackUserId": want.fallback_user[0] if want.fallback_user else "",
                "LibraryMappings": [],
                "UserMappings": [],
            },
        )
        return [
            Change(
                text=f"Added {want.peer} at {want.url} as a {want.mode} peer, signed in as "
                f"{signed_in.user}"
            )
        ]

    return edit


def _entry_conflicts(existing: JsonObject, want: EntryWant) -> list[Item]:
    name = entry_name(existing)

    def conflict(code: str, problem: str, fix: str) -> Attention:
        return Attention(
            code=code,
            subject=f"Peer {name}",
            problem=problem,
            fix=f"{fix}, then run `sea-nettle setup` again.",
        )

    items: list[Item] = []
    user = text(existing, "AuthenticatedUser")
    access = text(existing, "AccessLevel")
    wanted_access = "Administrator" if want.administrator else "User"
    if user.lower() != want.account.lower() or access.lower() != wanted_access.lower():
        # An entry signed in as another account could carry rights the spec does not ask for.
        items.append(
            conflict(
                "conflict-entry-account",
                f"its key belongs to {user or 'an API key'} ({access or 'unknown access'}), but "
                f"the spec says {want.account} ({wanted_access}).",
                f"Under {SERVERS}, sign the entry in as {want.account}, or delete it so setup "
                "adds it",
            )
        )
    if not same_url(text(existing, "Url"), want.url):
        items.append(
            conflict(
                "conflict-entry-url",
                f"its entry for server ID {want.server_id} uses {text(existing, 'Url')}, but "
                f"the spec says {want.url}.",
                f"Change the entry's URL under {SERVERS} and generate a new token there, "
                "or correct the spec's URL",
            )
        )
    if not flag(existing, "IsEnabled", default=True):
        items.append(
            conflict(
                "conflict-entry-disabled",
                "its entry is disabled, so it cannot pair or sync.",
                f"Enable the entry under {SERVERS}",
            )
        )
    mode = text(existing, "Mode") or "Pull"
    if mode not in (want.mode, "Sync"):
        items.append(
            conflict(
                "conflict-entry-mode",
                f"its entry's direction is {mode}, but this server needs {want.mode} or Sync.",
                f"Set the entry's direction to {want.mode} under {SERVERS}",
            )
        )
    if want.allow_linking and not flag(existing, "AllowLinking", default=False):
        items.append(
            conflict(
                "conflict-entry-linking",
                "its entry does not allow linking, so the replica's links cannot stream.",
                f"Turn on Allow Linking in the entry under {SERVERS}",
            )
        )
    if want.fallback_user is not None and normalize_id(
        text(existing, "LinkFallbackUserId")
    ) != normalize_id(want.fallback_user[0]):
        user = want.fallback_user[1]
        items.append(
            conflict(
                "conflict-entry-fallback",
                f"its key on this server belongs to the standard user {user}, which streams "
                "only as itself, but the entry's link fallback user is another user.",
                f"Set the entry's link fallback user to {user} under {SERVERS}",
            )
        )
    return items


@dataclass(kw_only=True, frozen=True)
class LibraryMappingWant:
    """A Link mapping from a source library to a replica library."""

    library: str
    source_library_id: str
    source_library_name: str
    source_path: str
    local_library_id: str
    local_library_name: str
    local_path: str
    # Server Sync's FilteredItems for a whitelist, or None for all content.
    whitelist: tuple[JsonObject, ...] | None
    # Whether every whitelist item was found on the source.
    complete: bool


def library_mapping(server_id: str, want: LibraryMappingWant, *, enable: bool) -> Edit:
    """Adds the mapping, disabled unless `enable`; enables an existing one when `enable`."""

    def edit(config: JsonObject) -> list[Item]:
        found = find_entry(config, server_id)
        if found is None:
            return []
        mappings = _list(found, "LibraryMappings")
        subject = f"Library {want.library}"
        for other in mappings:
            if (
                normalize_id(text(other, "LocalLibraryId")) == normalize_id(want.local_library_id)
                and strip_slash(text(other, "SourceRootPath")) != want.source_path
            ):
                return [
                    Attention(
                        code="conflict-mapping-library",
                        subject=subject,
                        problem=f"the replica library {want.local_library_name} is already "
                        f"mapped from {text(other, 'SourceRootPath') or 'another source path'}.",
                        fix=f"Remove that mapping under {SERVERS}, or give the spec library "
                        "another key, then run `sea-nettle setup` again.",
                    )
                ]
        mapping = next(
            (m for m in mappings if strip_slash(text(m, "SourceRootPath")) == want.source_path),
            None,
        )
        if mapping is None:
            enabled = enable and want.complete
            mappings_json = as_list(found["LibraryMappings"])
            mappings_json.append(
                {
                    "SourceLibraryId": want.source_library_id,
                    "SourceLibraryName": want.source_library_name,
                    "SourceRootPath": want.source_path,
                    "LocalLibraryId": want.local_library_id,
                    "LocalLibraryName": want.local_library_name,
                    "LocalRootPath": want.local_path,
                    "IsEnabled": enabled,
                    "FilterMode": "AllowAll" if want.whitelist is None else "Whitelist",
                    "FilteredItems": list(want.whitelist or ()),
                    "StorageMode": "Link",
                }
            )
            state = "enabled" if enabled else "disabled"
            return [Change(text=f"Mapped {want.library} to the replica as links ({state})")]
        conflicts = _mapping_conflicts(mapping, want)
        if conflicts:
            return conflicts
        items: list[Item] = []
        if want.whitelist is not None:
            items += _extend_whitelist(mapping, want)
        if enable and want.complete and not flag(mapping, "IsEnabled", default=True):
            mapping["IsEnabled"] = True
            items.append(Change(text=f"Enabled the mapping for {want.library}"))
        return items

    return edit


def _mapping_conflicts(mapping: JsonObject, want: LibraryMappingWant) -> list[Item]:
    def conflict(problem: str, fix: str) -> Attention:
        return Attention(
            code="conflict-mapping",
            subject=f"Library {want.library}",
            problem=f"its mapping from {want.source_path} {problem}",
            fix=f"Under {SERVERS}, {fix}, or delete the mapping, then run `sea-nettle setup` "
            "again.",
        )

    if normalize_id(text(mapping, "SourceLibraryId")) != normalize_id(want.source_library_id):
        return [
            conflict(
                "is for another source library, perhaps one that was deleted and created again.",
                "remove it",
            )
        ]
    if normalize_id(text(mapping, "LocalLibraryId")) != normalize_id(want.local_library_id):
        return [
            conflict(
                f"goes to {text(mapping, 'LocalLibraryName') or 'another library'}, not "
                f"{want.local_library_name}.",
                f"map it to {want.local_library_name}",
            )
        ]
    if strip_slash(text(mapping, "LocalRootPath")) != want.local_path:
        # Server Sync writes the links under this folder.
        return [
            conflict(
                f"writes to {text(mapping, 'LocalRootPath') or 'no folder'}, not "
                f"{want.local_path}.",
                f"set its local folder to {want.local_path}",
            )
        ]
    if text(mapping, "StorageMode") != "Link":
        return [
            conflict(
                f"stores {text(mapping, 'StorageMode') or 'Copy'}, not Link.",
                "set its storage to Link",
            )
        ]
    mode = text(mapping, "FilterMode") or "AllowAll"
    wanted = "AllowAll" if want.whitelist is None else "Whitelist"
    if mode != wanted:
        return [
            conflict(
                f"filters by {mode}, but the spec asks for {wanted}.", f"set its filter to {wanted}"
            )
        ]
    return []


def _extend_whitelist(mapping: JsonObject, want: LibraryMappingWant) -> list[Item]:
    items = _list(mapping, "FilteredItems")
    have = {strip_slash(text(i, "Path")) for i in items}
    added = [i for i in want.whitelist or () if strip_slash(text(i, "Path")) not in have]
    if not added:
        return []
    as_list(mapping["FilteredItems"]).extend(added)
    names = ", ".join(text(i, "Name") or posixpath.basename(text(i, "Path")) for i in added)
    return [Change(text=f"Added {names} to the whitelist of {want.library}")]


@dataclass(kw_only=True, frozen=True)
class UserMappingWant:
    source_user_id: str
    source_name: str
    local_user_id: str
    local_name: str


def user_mapping(server_id: str, want: UserMappingWant, *, enable: bool) -> Edit:
    """Maps a source user to their Peer Login account, disabled unless `enable`."""

    def edit(config: JsonObject) -> list[Item]:
        found = find_entry(config, server_id)
        if found is None:
            return []
        for mapping in _list(found, "UserMappings"):
            same_local = normalize_id(text(mapping, "LocalUserId")) == normalize_id(
                want.local_user_id
            )
            same_source = normalize_id(text(mapping, "SourceUserId")) == normalize_id(
                want.source_user_id
            )
            if same_local and same_source:
                if enable and not flag(mapping, "IsEnabled", default=True):
                    mapping["IsEnabled"] = True
                    return [Change(text=f"Enabled the user mapping for {want.local_name}")]
                return []
            if same_local or same_source:
                return [
                    Attention(
                        code="conflict-user-mapping",
                        subject=f"User {want.local_name}",
                        problem=f"a user mapping already maps {text(mapping, 'SourceUserName')} "
                        f"to {text(mapping, 'LocalUserName')}.",
                        fix=f"Under {SERVERS}, step 4 Users, remove that mapping, then run "
                        "`sea-nettle setup` again.",
                    )
                ]
        _append(
            found,
            "UserMappings",
            {
                "SourceUserId": want.source_user_id,
                "SourceUserName": want.source_name,
                "LocalUserId": want.local_user_id,
                "LocalUserName": want.local_name,
                "IsEnabled": enable,
            },
        )
        state = "enabled" if enable else "disabled"
        return [Change(text=f"Mapped user {want.local_name} to the source ({state})")]

    return edit


def has_enabled_user_mapping(config: JsonObject, server_id: str) -> bool:
    found = find_entry(config, server_id)
    return found is not None and any(
        flag(m, "IsEnabled", default=True) for m in _list(found, "UserMappings")
    )


def switch_on(key: str, label: str, *, when: Callable[[JsonObject], bool] | None = None) -> Edit:
    """Turns on a Server Sync feature, when `when` holds for the document as edited so far."""

    def edit(config: JsonObject) -> list[Item]:
        if flag(config, key, default=False) or (when is not None and not when(config)):
            return []
        config[key] = True
        return [Change(text=f"Turned on {label}")]

    return edit
