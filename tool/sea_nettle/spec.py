"""The setup specification: what `sea-nettle setup` makes true on a source and a replica.

`parse` checks the whole specification, including combinations that Server Sync cannot
honour, before `setup` changes anything (R-PAIR-5).
"""

from __future__ import annotations

import posixpath
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .model import as_list, as_object

Role = Literal["source", "replica"]

# Jellyfin's `collectionType` values for new libraries.
LIBRARY_TYPES = (
    "movies",
    "tvshows",
    "music",
    "musicvideos",
    "homevideos",
    "boxsets",
    "books",
    "mixed",
)
# Jellyfin's user name rule (`UserManager.ValidUsernameRegex`).
USER_NAME = re.compile(r"^(?!\s)[\w\ \-'._@+]+(?<!\s)$")
# Characters Jellyfin replaces in a library's folder name (`GetValidFilename`), so a library
# named with them would not be found by its name again.
LIBRARY_NAME_FORBIDDEN = re.compile(r'[\x00-\x1f"<>|:*?\\/]')
# Library keys name the replica's library directory.
LIBRARY_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# The same rule as Peer Login's source URL (R-LOGIN-7): HTTPS, or HTTP to loopback.
PEER_URL = re.compile(
    r"^(https://([^/:]+|\[[0-9a-f:.]+\])|http://(localhost|127\.[0-9.]+|\[::1\]))(:[0-9]+)?(/.*)?$",
    re.IGNORECASE,
)


@dataclass(kw_only=True, frozen=True)
class SyncAccount:
    """A dedicated account on one server that the other server's entry signs in as."""

    name: str
    password_file: Path
    administrator: bool


@dataclass(kw_only=True, frozen=True)
class Server:
    url: str
    sync_account: SyncAccount


@dataclass(kw_only=True, frozen=True)
class Whitelist:
    """Top-level items to sync, as paths relative to the library's source path."""

    paths: tuple[str, ...]


@dataclass(kw_only=True, frozen=True)
class AllContent:
    pass


@dataclass(kw_only=True, frozen=True)
class Library:
    key: str
    name: str
    type: str
    source_path: str
    content: AllContent | Whitelist

    def whitelist_paths(self) -> tuple[str, ...]:
        if isinstance(self.content, AllContent):
            return ()
        return tuple(posixpath.join(self.source_path, p) for p in self.content.paths)


@dataclass(kw_only=True, frozen=True)
class Person:
    """An ordinary source user."""

    name: str
    # Creates the user when it is missing; None requires it to exist.
    password_file: Path | None


@dataclass(kw_only=True, frozen=True)
class Spec:
    source: Server
    replica: Server
    libraries: tuple[Library, ...]
    # Mapped to their Peer Login accounts on the replica when the source account is an
    # administrator: such a key streams links as the user the replica maps.
    users: tuple[Person, ...]
    # Whether the mapped users' watch history syncs to the replica.
    sync_history: bool

    def server(self, role: Role) -> Server:
        return self.source if role == "source" else self.replica

    def peer(self, role: Role) -> Server:
        return self.replica if role == "source" else self.source


class _Errors:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, where: str, message: str) -> None:
        self.items.append(f"{where}: {message}")


def parse(value: object, *, role: Role, admin_name: str) -> Spec | list[str]:
    """The specification, or every problem with it."""
    errors = _Errors()
    try:
        spec = _parse(as_object(value), errors)
    except ValueError as e:
        return [f"spec: {e}"]
    if spec is not None:
        _check(spec, errors, role=role, admin_name=admin_name)
    if errors.items or spec is None:
        return errors.items or ["spec: invalid"]
    return spec


def _fields(obj: dict[str, object], where: str, errors: _Errors, allowed: set[str]) -> None:
    for key in sorted(set(obj) - allowed):
        errors.add(where, f'unknown field "{key}"')


def _text(obj: dict[str, object], key: str, where: str, errors: _Errors) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        errors.add(where, f'"{key}" must be a non-empty string')
        return ""
    return value


def _bool(obj: dict[str, object], key: str, where: str, errors: _Errors) -> bool:
    value = obj.get(key)
    if not isinstance(value, bool):
        errors.add(where, f'"{key}" must be true or false')
        return False
    return value


def _path(value: str, where: str, key: str, errors: _Errors) -> str:
    if value and (not value.startswith("/") or posixpath.normpath(value) != value):
        errors.add(where, f'"{key}" must be an absolute path without "..", "." or a trailing "/"')
    return value


def _parse(obj: dict[str, object], errors: _Errors) -> Spec | None:
    _fields(obj, "spec", errors, {"source", "replica", "libraries", "users", "syncHistory"})
    source = _server(obj.get("source"), "source", errors)
    replica = _server(obj.get("replica"), "replica", errors)
    libraries = tuple(
        lib
        for i, item in enumerate(as_list(obj.get("libraries")))
        if (lib := _library(item, f"libraries[{i}]", errors)) is not None
    )
    users = tuple(
        user
        for i, item in enumerate(as_list(obj.get("users")))
        if (user := _user(item, f"users[{i}]", errors)) is not None
    )
    sync_history = _bool(obj, "syncHistory", "spec", errors)
    if source is None or replica is None:
        return None
    return Spec(
        source=source,
        replica=replica,
        libraries=libraries,
        users=users,
        sync_history=sync_history,
    )


def _object(value: object, where: str, errors: _Errors) -> dict[str, object] | None:
    try:
        return as_object(value)
    except ValueError:
        errors.add(where, "must be an object")
        return None


def _server(value: object, where: str, errors: _Errors) -> Server | None:
    obj = _object(value, where, errors)
    if obj is None:
        return None
    _fields(obj, where, errors, {"url", "syncAccount"})
    url = _text(obj, "url", where, errors).rstrip("/")
    if url and not PEER_URL.match(url):
        errors.add(where, '"url" must use HTTPS unless it is a loopback address')
    account_where = f"{where}.syncAccount"
    account_obj = _object(obj.get("syncAccount"), account_where, errors)
    if account_obj is None:
        return None
    _fields(account_obj, account_where, errors, {"name", "passwordFile", "administrator"})
    name = _text(account_obj, "name", account_where, errors)
    password_file = _path(
        _text(account_obj, "passwordFile", account_where, errors),
        account_where,
        "passwordFile",
        errors,
    )
    administrator = _bool(account_obj, "administrator", account_where, errors)
    _user_name(name, account_where, errors)
    return Server(
        url=url,
        sync_account=SyncAccount(
            name=name, password_file=Path(password_file), administrator=administrator
        ),
    )


def _library(value: object, where: str, errors: _Errors) -> Library | None:
    obj = _object(value, where, errors)
    if obj is None:
        return None
    _fields(obj, where, errors, {"key", "name", "type", "sourcePath", "content"})
    key = _text(obj, "key", where, errors)
    if key and not LIBRARY_KEY.match(key):
        errors.add(where, '"key" may hold only letters, digits, ".", "_" and "-"')
    name = _text(obj, "name", where, errors)
    if name != name.strip():
        errors.add(where, '"name" must not start or end with spaces')
    if LIBRARY_NAME_FORBIDDEN.search(name):
        errors.add(where, '"name" must not contain control characters or any of " < > | : * ? \\ /')
    library_type = _text(obj, "type", where, errors)
    if library_type and library_type not in LIBRARY_TYPES:
        errors.add(where, f'"type" must be one of {", ".join(LIBRARY_TYPES)}')
    source_path = _path(_text(obj, "sourcePath", where, errors), where, "sourcePath", errors)
    return Library(
        key=key,
        name=name,
        type=library_type,
        source_path=source_path,
        content=_content(obj.get("content"), where, errors),
    )


def _content(value: object, where: str, errors: _Errors) -> AllContent | Whitelist:
    if value == "all":
        return AllContent()
    obj = None if isinstance(value, str) else _object(value, f"{where}.content", errors)
    if obj is not None:
        _fields(obj, f"{where}.content", errors, {"whitelist"})
        paths = as_list(obj.get("whitelist")) if isinstance(obj.get("whitelist"), list) else []
        if paths and all(isinstance(p, str) for p in paths):
            items = tuple(str(p) for p in paths)
            for item in items:
                if (
                    item.startswith("/")
                    or posixpath.normpath(item) != item
                    or item == "."
                    or ".." in item.split("/")
                ):
                    errors.add(
                        where, f'whitelist item "{item}" must be a path relative to sourcePath'
                    )
            return Whitelist(paths=items)
    errors.add(where, '"content" must be "all" or {"whitelist": [paths relative to sourcePath]}')
    return AllContent()


def _user(value: object, where: str, errors: _Errors) -> Person | None:
    obj = _object(value, where, errors)
    if obj is None:
        return None
    _fields(obj, where, errors, {"name", "passwordFile"})
    name = _text(obj, "name", where, errors)
    _user_name(name, where, errors)
    password_file = obj.get("passwordFile")
    if password_file is not None and not isinstance(password_file, str):
        errors.add(where, '"passwordFile" must be a path or null')
        password_file = None
    if password_file:
        _path(password_file, where, "passwordFile", errors)
    return Person(
        name=name,
        password_file=Path(password_file) if password_file else None,
    )


def _user_name(name: str, where: str, errors: _Errors) -> None:
    if name and (not USER_NAME.match(name) or name in (".", "..")):
        errors.add(where, f'"{name}" is not a valid Jellyfin user name')


def _duplicates(values: list[str]) -> list[str]:
    seen: set[str] = set()
    found: list[str] = []
    for value in values:
        if value in seen and value not in found:
            found.append(value)
        seen.add(value)
    return found


def _check(spec: Spec, errors: _Errors, *, role: Role, admin_name: str) -> None:
    if spec.source.url and spec.source.url.lower() == spec.replica.url.lower():
        errors.add("spec", "source.url and replica.url must differ")
    for key in _duplicates([lib.key for lib in spec.libraries]):
        errors.add("libraries", f'key "{key}" is used twice')
    for name in _duplicates([lib.name.lower() for lib in spec.libraries]):
        errors.add("libraries", f'name "{name}" is used twice')
    for path in _duplicates([lib.source_path for lib in spec.libraries]):
        errors.add("libraries", f'sourcePath "{path}" is used twice')
    user_names = [u.name.lower() for u in spec.users]
    for name in _duplicates(user_names):
        errors.add("users", f'"{name}" is listed twice')
    # Sync accounts are dedicated: no person signs in with them, and Peer Login creates
    # replica users with source user names.
    for where, account in [
        ("source.syncAccount", spec.source.sync_account),
        ("replica.syncAccount", spec.replica.sync_account),
    ]:
        if account.name.lower() in user_names:
            errors.add(where, f'"{account.name}" is also listed under users')
    own = spec.server(role).sync_account
    if own.name.lower() == admin_name.lower():
        errors.add(
            f"{role}.syncAccount",
            f'"{own.name}" is this server\'s administrator; use a dedicated account',
        )
    # R-PAIR-5: Server Sync syncs only the key user's own history with a standard user's key
    # (`SourceServer.MaySyncUser`), so a limited source account cannot carry other users'.
    if spec.sync_history and not spec.source.sync_account.administrator:
        errors.add(
            "spec",
            "syncHistory needs source.syncAccount.administrator = true: with a limited "
            "account, Server Sync syncs only that account's own history. Make the source "
            "sync account an administrator, or set syncHistory to false",
        )
