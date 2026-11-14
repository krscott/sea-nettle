"""Typed views of the Jellyfin and Server Sync JSON that the commands read.

Server Sync returns each peer's stored API key with its configuration. The views
keep only whether a key is present, so no key material outlives parsing (R-PAIR-2).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import cast

SERVER_SYNC_ID = "ebd650b5-6f4c-4ccb-b10d-23dffb3a7286"
PEER_LOGIN_PROVIDER = "Jellyfin.Plugin.PeerLogin.PeerAuthenticationProvider"
# Server Sync resolves this in place of an API key to the key it stores for the entry.
KEPT_API_KEY = "__JPK_SECRET_KEPT__"
# Server Sync's `ServerMode`, in declaration order.
MODES = ("Pull", "Push", "Sync")


def as_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object, got {type(value).__name__}")
    return cast(dict[str, object], value)


def as_list(value: object) -> list[object]:
    """A JSON array; Server Sync can serialize an empty list as null."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"expected a JSON array, got {type(value).__name__}")
    return cast(list[object], value)


def text(obj: dict[str, object], key: str) -> str:
    value = obj.get(key)
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ValueError(f"{key}: expected a string, got {type(value).__name__}")
    return value


def optional_text(obj: dict[str, object], key: str) -> str | None:
    return text(obj, key) or None


def flag(obj: dict[str, object], key: str, *, default: bool) -> bool:
    value = obj.get(key)
    if value is None:
        return default
    if not isinstance(value, bool):
        raise ValueError(f"{key}: expected a boolean, got {type(value).__name__}")
    return value


def mode(value: object) -> str:
    """A `ServerMode`, which Jellyfin's JSON writes by name."""
    if value is None:
        return MODES[0]
    if isinstance(value, int) and not isinstance(value, bool) and 0 <= value < len(MODES):
        return MODES[value]
    if isinstance(value, str) and value in MODES:
        return value
    raise ValueError(f"Mode: unexpected value {value!r}")


def same_id(a: str, b: str) -> bool:
    """Jellyfin and Server Sync write the same GUID with and without dashes."""
    return normalize_id(a) == normalize_id(b)


def normalize_id(value: str) -> str:
    return value.strip().replace("-", "").lower()


@dataclass(kw_only=True, frozen=True)
class Plugin:
    version: str
    status: str

    @staticmethod
    def find(plugins: object, plugin_id: str) -> Plugin | None:
        for item in as_list(plugins):
            obj = as_object(item)
            if same_id(text(obj, "Id"), plugin_id):
                return Plugin(version=text(obj, "Version"), status=text(obj, "Status"))
        return None


@dataclass(kw_only=True, frozen=True)
class LibraryMapping:
    source_name: str
    local_id: str
    local_name: str
    enabled: bool

    @staticmethod
    def from_json(value: object) -> LibraryMapping:
        obj = as_object(value)
        return LibraryMapping(
            source_name=text(obj, "SourceLibraryName"),
            local_id=text(obj, "LocalLibraryId"),
            local_name=text(obj, "LocalLibraryName"),
            enabled=flag(obj, "IsEnabled", default=True),
        )


@dataclass(kw_only=True, frozen=True)
class UserMapping:
    source_id: str
    source_name: str
    local_id: str
    local_name: str
    enabled: bool

    @staticmethod
    def from_json(value: object) -> UserMapping:
        obj = as_object(value)
        return UserMapping(
            source_id=text(obj, "SourceUserId"),
            source_name=text(obj, "SourceUserName"),
            local_id=text(obj, "LocalUserId"),
            local_name=text(obj, "LocalUserName"),
            enabled=flag(obj, "IsEnabled", default=True),
        )


@dataclass(kw_only=True, frozen=True)
class Entry:
    """One peer entry in Server Sync's `Servers` list."""

    key: str
    name: str
    url: str
    has_api_key: bool
    allow_private_network: bool
    mode: str
    server_id: str
    enabled: bool
    access_level: str
    authenticated_user: str
    authenticated_user_id: str
    library_mappings: tuple[LibraryMapping, ...]
    user_mappings: tuple[UserMapping, ...]

    @staticmethod
    def from_json(value: object) -> Entry:
        obj = as_object(value)
        url = text(obj, "Url")
        return Entry(
            key=text(obj, "Key"),
            # Server Sync's DisplayName.
            name=text(obj, "Name").strip() or text(obj, "ServerName").strip() or url,
            url=url,
            has_api_key=bool(text(obj, "ApiKey")),
            allow_private_network=flag(obj, "AllowPrivateNetwork", default=True),
            mode=mode(obj.get("Mode")),
            server_id=text(obj, "ServerId"),
            enabled=flag(obj, "IsEnabled", default=True),
            access_level=text(obj, "AccessLevel"),
            authenticated_user=text(obj, "AuthenticatedUser"),
            authenticated_user_id=text(obj, "AuthenticatedUserId"),
            library_mappings=tuple(
                LibraryMapping.from_json(m) for m in as_list(obj.get("LibraryMappings"))
            ),
            user_mappings=tuple(UserMapping.from_json(m) for m in as_list(obj.get("UserMappings"))),
        )

    @staticmethod
    def list_from_config(config: object) -> tuple[Entry, ...]:
        return tuple(Entry.from_json(s) for s in as_list(as_object(config).get("Servers")))


@dataclass(kw_only=True, frozen=True)
class User:
    id: str
    name: str
    peer_login: bool

    @staticmethod
    def from_json(value: object) -> User:
        obj = as_object(value)
        policy = as_object(obj.get("Policy") or {})
        return User(
            id=text(obj, "Id"),
            name=text(obj, "Name"),
            peer_login=text(policy, "AuthenticationProviderId") == PEER_LOGIN_PROVIDER,
        )


@dataclass(kw_only=True, frozen=True)
class LinkCheck:
    """The fields of Server Sync's `PeerCheckResult` that the report uses."""

    reachable: bool
    server_id: str
    peer_mode: str | None
    paired: bool
    pairing_error: str | None
    severity: str
    message: str

    @staticmethod
    def from_json(value: object) -> LinkCheck:
        obj = as_object(value)
        return LinkCheck(
            reachable=flag(obj, "Reachable", default=False),
            server_id=text(obj, "ServerId"),
            peer_mode=optional_text(obj, "PeerMode"),
            paired=flag(obj, "Paired", default=False),
            pairing_error=optional_text(obj, "PairingError"),
            severity=text(obj, "Severity"),
            message=text(obj, "Message"),
        )
