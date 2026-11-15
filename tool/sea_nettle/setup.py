"""`sea-nettle setup`: makes this server's side of the spec true, then reports like `status`.

Each run works on its own server only, signed in as its administrator. It adds what is
missing and enables what the spec asks for once the link check passes; it never removes,
disables, or rewrites what exists (R-PAIR-6). Steps that need the peer's side wait for a
later run, after `setup` has run there.
"""

from __future__ import annotations

import sys
import time
import urllib.parse
from collections.abc import Generator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from . import edits
from .edits import Change, Edit, EntryWant, Item, JsonObject, SignedIn
from .jellyfin import Fatal, HttpStatus, Jellyfin, read_secret
from .model import (
    PEER_LOGIN_PROVIDER,
    SERVER_SYNC_ID,
    Entry,
    Plugin,
    as_list,
    as_object,
    flag,
    normalize_id,
    text,
)
from .report import RECORD_ID, SERVERS, Attention, link_attention
from .spec import AllContent, Library, Role, Spec, SyncAccount
from .status import check_link

CONFIG = f"/Plugins/{SERVER_SYNC_ID}/Configuration"
LIBRARIES = "Dashboard > Libraries"
USERS = "Dashboard > Users"
RERUN = "then run `sea-nettle setup` again"
# Library options that keep generated metadata, artwork, subtitles, lyrics and trickplay in
# Jellyfin's own state rather than beside the media (R-PAIR-8).
STATE_ONLY_OPTIONS: JsonObject = {
    "SaveLocalMetadata": False,
    "MetadataSavers": [],
    "SaveSubtitlesWithMedia": False,
    "SaveLyricsWithMedia": False,
    "SaveTrickplayWithMedia": False,
}
# Jellyfin fills in a new library's item ID shortly after creating it.
LIBRARY_ID_TIMEOUT = 60
# Calls that make Server Sync call the peer.
PEER_TIMEOUT = 120


@dataclass(kw_only=True, frozen=True)
class Outcome:
    changes: tuple[str, ...]
    attention: tuple[Attention, ...]
    waiting: tuple[Attention, ...]


class Run:
    """One setup run on this server."""

    def __init__(self, api: Jellyfin, spec: Spec, *, role: Role, replica_root: Path | None) -> None:
        self.api = api
        self.spec = spec
        self.role: Role = role
        self.replica_root = replica_root
        self.items: list[Item] = []
        self.waiting: list[Attention] = []
        # The spec's libraries on this server, by key, once `ensure_libraries` has run.
        self.library_ids: dict[str, str] = {}

    @property
    def other(self) -> str:
        return "replica" if self.role == "source" else "source"

    def outcome(self) -> Outcome:
        return Outcome(
            changes=tuple(i.text for i in self.items if isinstance(i, Change)),
            attention=tuple(i for i in self.items if isinstance(i, Attention)),
            waiting=tuple(self.waiting),
        )

    def note(self, code: str, subject: str, problem: str, fix: str) -> None:
        self.items.append(Attention(code=code, subject=subject, problem=problem, fix=fix))

    def config(self) -> JsonObject:
        """Server Sync's configuration document, with no key material in it."""
        config = as_object(self.api.get(CONFIG))
        edits.keep_stored_keys(config)
        return config

    def edit_config(self, edit_list: list[Edit]) -> bool:
        """Applies the edits to the document as it is now, and saves it if they changed it.

        Returns whether it saved.
        """
        config = self.config()
        items = [item for edit in edit_list for item in edit(config)]
        changed = any(isinstance(i, Change) for i in items)
        if changed:
            self.api.request("POST", CONFIG, config)
        self.items += items
        return changed

    # Users

    def users(self) -> dict[str, JsonObject]:
        """Local users by lower-case name; Jellyfin compares user names ignoring case."""
        return {text(u, "Name").lower(): u for u in map(as_object, as_list(self.api.get("/Users")))}

    def create_user(self, name: str, password_file: Path) -> JsonObject:
        password = read_secret(password_file, what=f"{name}'s password file")
        return as_object(
            self.api.request("POST", "/Users/New", {"Name": name, "Password": password})
        )

    def ensure_people(self) -> None:
        users = self.users()
        for person in self.spec.users:
            if person.name.lower() in users:
                continue
            if person.password_file is None:
                self.note(
                    "user-missing",
                    f"User {person.name}",
                    "the user does not exist on the source, and the spec gives no passwordFile.",
                    f"Create {person.name} under {USERS}, or give a passwordFile; {RERUN}.",
                )
                continue
            self.create_user(person.name, person.password_file)
            self.items.append(Change(text=f"Created user {person.name}"))

    def ensure_sync_account(
        self, account: SyncAccount, *, library_ids: list[str]
    ) -> JsonObject | None:
        """The sync account the peer signs in as, or None when it is unusable as specified."""
        subject = f"User {account.name}"
        existing = self.users().get(account.name.lower())
        if existing is None:
            user = self.create_user(account.name, account.password_file)
            policy = as_object(user.get("Policy"))
            if account.administrator:
                policy["IsAdministrator"] = True
            else:
                # A limited account sees only the spec's libraries.
                policy["EnableAllFolders"] = False
                policy["EnabledFolders"] = library_ids
            self.api.request("POST", f"/Users/{text(user, 'Id')}/Policy", policy)
            kind = "administrator" if account.administrator else "limited"
            self.items.append(Change(text=f"Created the {kind} sync account {account.name}"))
            return user
        policy = as_object(existing.get("Policy"))
        administrator = flag(policy, "IsAdministrator", default=False)
        if administrator != account.administrator:
            # Never grant or remove administrator rights (R-PAIR-6); never let a peer in with
            # more rights than the spec asks for.
            self.note(
                "conflict-sync-account",
                subject,
                f"the spec asks for {_kind(account.administrator)}, but the existing account "
                f"is {_kind(administrator)}.",
                f"Change the account under {USERS}, or the spec's administrator setting; "
                f"{RERUN}.",
            )
            return None
        if flag(policy, "IsDisabled", default=False):
            self.note(
                "conflict-sync-account",
                subject,
                "the sync account is disabled.",
                f"Enable it under {USERS}; {RERUN}.",
            )
            return None
        if not administrator:
            fix = f"Under {USERS}, {account.name}, Access, allow exactly the spec's libraries; {RERUN}."
            if flag(policy, "EnableAllFolders", default=True):
                # A run stopped between creating the account and limiting it leaves this.
                self.note(
                    "sync-account-library-access",
                    subject,
                    "the limited sync account can see every library, not only the spec's.",
                    fix,
                )
                return None
            enabled = {normalize_id(str(i)) for i in as_list(policy.get("EnabledFolders"))}
            if any(normalize_id(i) not in enabled for i in library_ids):
                self.note(
                    "sync-account-library-access",
                    subject,
                    "the sync account cannot see every library in the spec.",
                    fix,
                )
        return existing

    def ensure_grant(self) -> JsonObject | None:
        """This server's sync account, allowed to call Server Sync, or None if unusable."""
        account = self.spec.server(self.role).sync_account
        library_ids = list(self.library_ids.values())
        user = self.ensure_sync_account(account, library_ids=library_ids)
        if user is None:
            return None
        self.edit_config([edits.grant(user_id=text(user, "Id"), user_name=text(user, "Name"))])
        return user

    # Libraries

    def libraries(self) -> dict[str, JsonObject]:
        return {
            text(f, "Name"): f
            for f in map(as_object, as_list(self.api.get("/Library/VirtualFolders")))
        }

    def ensure_libraries(self) -> None:
        """Creates the spec's libraries here; `library_ids` maps their keys to IDs."""
        self.library_ids = {}
        for library in self.spec.libraries:
            library_id = self.ensure_library(library, path=self.library_path(library))
            if library_id:
                self.library_ids[library.key] = library_id

    def library_path(self, library: Library) -> str:
        if self.role == "source":
            return library.source_path
        assert self.replica_root is not None
        return str(self.replica_root / library.key)

    def ensure_library(self, library: Library, *, path: str) -> str | None:
        """The ID of the library named in the spec, created at `path` when missing."""
        subject = f"Library {library.name}"
        existing = self.libraries().get(library.name)
        if existing is not None:
            locations = {edits.strip_slash(str(p)) for p in as_list(existing.get("Locations"))}
            if path not in locations:
                self.note(
                    "conflict-library-path",
                    subject,
                    f"the existing library does not include {path}.",
                    f"Add {path} to it under {LIBRARIES}, or rename the spec's library; "
                    f"{RERUN}.",
                )
                return None
            kind = text(existing, "CollectionType")
            if kind and kind.lower() != library.type:
                self.note(
                    "conflict-library-type",
                    subject,
                    f"the existing library holds {kind}, but the spec says {library.type}.",
                    f"Correct the spec's type, or rename the spec's library; {RERUN}.",
                )
                return None
            options = as_object(existing.get("LibraryOptions") or {})
            if self.role == "source" and writes_beside_media(options):
                self.note(
                    "library-writes-beside-media",
                    subject,
                    "it saves metadata, artwork, subtitles, lyrics or trickplay beside the "
                    "media, which Jellyfin cannot write.",
                    f"Under {LIBRARIES}, {library.name}, turn off saving them into media folders.",
                )
            return text(existing, "ItemId") or self.wait_for_library_id(library.name)
        if not Path(path).is_dir():
            fix = (
                "Mount the media, or correct the spec's sourcePath"
                if self.role == "source"
                else "Rebuild the system, which creates the replica's library folders"
            )
            self.note(
                "library-folder-missing",
                subject,
                f"its folder {path} does not exist.",
                f"{fix}; {RERUN}.",
            )
            return None
        query = urllib.parse.urlencode(
            {
                "name": library.name,
                "collectionType": library.type,
                "paths": path,
                "refreshLibrary": "true",
            }
        )
        self.api.request(
            "POST",
            f"/Library/VirtualFolders?{query}",
            {"LibraryOptions": {**STATE_ONLY_OPTIONS, "PathInfos": [{"Path": path}]}},
        )
        self.items.append(Change(text=f"Created library {library.name} at {path}"))
        return self.wait_for_library_id(library.name)

    def wait_for_library_id(self, name: str) -> str:
        deadline = time.monotonic() + LIBRARY_ID_TIMEOUT
        while True:
            library_id = text(self.libraries().get(name) or {}, "ItemId")
            if library_id:
                return library_id
            if time.monotonic() > deadline:
                raise Fatal(f"Jellyfin did not finish creating the library {name}; {RERUN}.")
            time.sleep(1)

    # Peers

    def peer_id(self) -> str | None:
        """The peer's server ID, from its anonymous system information."""
        url = self.spec.peer(self.role).url
        try:
            info = as_object(Jellyfin(url).get("/System/Info/Public"))
        except Fatal as e:
            self.note(
                "setup-peer-unreachable",
                f"Peer {url}",
                f"this server cannot reach it: {e}",
                f"Check that Jellyfin runs there and that this host can open {url}; {RERUN}. "
                "Everything that does not need the peer is set up.",
            )
            return None
        return text(info, "Id")

    def ensure_entry(self, want: EntryWant) -> Entry | None:
        """The entry for the peer, added when missing, or None while it is unusable."""
        config = self.config()
        if edits.find_entry(config, want.server_id) is None:
            stale = next(
                (
                    e
                    for e in as_list(config.get("Servers"))
                    if edits.same_url(text(as_object(e), "Url"), want.url)
                ),
                None,
            )
            if stale is not None:
                # Signing in again would revoke that entry's key.
                recorded = text(as_object(stale), "ServerId") or "no server ID"
                self.note(
                    "conflict-entry-server-id",
                    f"Peer {want.url}",
                    f"an entry for it records {recorded}, but the server there reports "
                    f"{want.server_id}.",
                    f"Open the entry under {SERVERS} and, {RECORD_ID}; or delete it; {RERUN}.",
                )
                return None
            signed_in = self.sign_in_to_peer(want.server_id)
            if signed_in is None:
                return None
            with self.unsaved_token_ends(signed_in) as keep:
                try:
                    if self.edit_config([edits.entry(want, signed_in)]):
                        keep()
                except BaseException:
                    # A save that Jellyfin took before a failure or an interruption, such as
                    # an answer that came too late, holds the token.
                    if self.entry_saved(want.server_id, signed_in):
                        keep()
                    raise
        else:
            self.edit_config([edits.entry(want, None)])
        found = edits.find_entry(self.config(), want.server_id)
        if found is None or any(
            isinstance(i, Attention) and i.code.startswith("conflict-entry") for i in self.items
        ):
            return None
        return Entry.from_json(found)

    def entry_saved(self, server_id: str, signed_in: SignedIn) -> bool:
        try:
            found = edits.find_entry(self.config(), server_id)
        except Fatal:
            return False
        return found is not None and text(found, "AuthenticatedUser") == signed_in.user

    def sign_in_to_peer(self, server_id: str) -> SignedIn | None:
        """Signs Server Sync in to the peer's sync account, for a new entry's key.

        Server Sync's sign-in revokes the token it got earlier for the same account, so
        this runs only when there is no entry to keep.
        """
        peer = self.spec.peer(self.role)
        account = peer.sync_account
        password = read_secret(account.password_file, what=f"{account.name}'s password file")
        answer = as_object(
            self.api.request(
                "POST",
                "/Sync/Authenticate",
                {
                    "ServerUrl": peer.url,
                    "Username": account.name,
                    "Password": password,
                    "AllowPrivateNetwork": True,
                },
                timeout=PEER_TIMEOUT,
            )
        )
        if not flag(answer, "Success", default=False):
            self.note(
                "setup-peer-sign-in",
                f"Peer {peer.url}",
                f"Server Sync could not sign in there as {account.name}: "
                f"{text(answer, 'Message') or 'no reason was given'}",
                f"Run `sudo sea-nettle setup` on the {self.other} first, which creates "
                f"{account.name}, and check that {account.password_file} holds its password; "
                f"{RERUN}.",
            )
            return None
        signed_in = SignedIn(
            token=text(answer, "AccessToken"),
            user=text(answer, "Username") or account.name,
            user_id=text(answer, "UserId"),
            administrator=flag(answer, "IsAdministrator", default=False),
            can_download=_optional_flag(answer, "CanDownload"),
            server_name=text(answer, "ServerName"),
            server_id=text(answer, "ServerId"),
        )
        with self.unsaved_token_ends(signed_in) as keep:
            if normalize_id(signed_in.server_id) != normalize_id(server_id):
                self.note(
                    "conflict-peer-id",
                    f"Peer {peer.url}",
                    f"it reported server ID {server_id}, then {signed_in.server_id} at sign-in.",
                    f"Check that {peer.url} reaches one server; {RERUN}.",
                )
                return None
            if signed_in.administrator != account.administrator:
                self.note(
                    "conflict-sync-account",
                    f"User {account.name}",
                    f"the spec asks for {_kind(account.administrator)} on the {self.other}, "
                    f"but it is {_kind(signed_in.administrator)}.",
                    f"Change the account there under {USERS}, or the spec; {RERUN}.",
                )
                return None
            keep()
        return signed_in

    @contextmanager
    def unsaved_token_ends(self, signed_in: SignedIn) -> Generator[_Keep]:
        """Ends the peer session behind a token unless the block calls the yielded `keep`,
        even on failure or interruption (R-PAIR-3)."""
        keep = _Keep()
        try:
            yield keep
        finally:
            if not keep.kept:
                self.end_peer_session(signed_in)

    def end_peer_session(self, signed_in: SignedIn) -> None:
        peer = self.spec.peer(self.role).url
        try:
            Jellyfin(peer, token=signed_in.token).request("POST", "/Sessions/Logout")
        except Fatal as e:
            # Printed at once: a failed or interrupted run prints no report (R-PAIR-3).
            print(
                f"sea-nettle: could not end the session that setup opened on the {self.other} as "
                f"{signed_in.user}: {e} On the {self.other}, remove the Server Sync device of "
                f"{signed_in.user} under Dashboard > Devices.",
                file=sys.stderr,
            )


class _Keep:
    def __init__(self) -> None:
        self.kept = False

    def __call__(self) -> None:
        self.kept = True


def _kind(administrator: bool) -> str:
    return "an administrator" if administrator else "a limited account"


def _optional_flag(obj: JsonObject, key: str) -> bool | None:
    value = obj.get(key)
    return value if isinstance(value, bool) else None


def writes_beside_media(options: JsonObject) -> bool:
    return (
        flag(options, "SaveLocalMetadata", default=False)
        or bool(as_list(options.get("MetadataSavers")))
        or flag(options, "SaveSubtitlesWithMedia", default=True)
        or flag(options, "SaveLyricsWithMedia", default=False)
        or flag(options, "SaveTrickplayWithMedia", default=False)
    )


def entry_want(run: Run, *, server_id: str, account: JsonObject) -> EntryWant:
    peer = run.spec.peer(run.role)
    own = run.spec.server(run.role).sync_account
    source = run.role == "source"
    return EntryWant(
        peer=f"the {run.other}",
        url=peer.url,
        server_id=server_id,
        mode="Push" if source else "Pull",
        allow_linking=source,
        account=peer.sync_account.name,
        administrator=peer.sync_account.administrator,
        # A standard user's key streams links only as that user.
        fallback_user=(
            (text(account, "Id"), text(account, "Name"))
            if source and not own.administrator
            else None
        ),
    )


def run_setup(run: Run) -> None:
    if run.role == "source":
        run.ensure_people()
    run.ensure_libraries()
    account = run.ensure_grant()
    if account is None:
        return
    server_id = run.peer_id()
    if server_id is None:
        return
    entry = run.ensure_entry(entry_want(run, server_id=server_id, account=account))
    if entry is None or run.role == "source":
        return
    # R-PAIR-7: mappings are enabled only once this server's link check passes.
    linked = not link_attention(entry, check_link(run.api, entry))
    edit_list = mapping_edits(run, entry, server_id=server_id, enable=linked)
    if not edit_list:
        return
    if linked:
        edit_list.append(
            edits.switch_on(
                "EnableContentSync",
                "content sync",
                when=lambda c: edits.has_enabled_library_mapping(c, server_id),
            )
        )
        if run.spec.sync_history:
            edit_list.append(
                edits.switch_on(
                    "EnableHistorySync",
                    "watch history sync",
                    when=lambda c: edits.has_enabled_user_mapping(c, server_id),
                )
            )
    else:
        run.note(
            "setup-mappings-disabled",
            f"Peer {entry.name}",
            "new and disabled mappings stay disabled until the link check passes.",
            f"Fix the peer's problem below, {RERUN}.",
        )
    run.edit_config(edit_list)


def mapping_edits(run: Run, entry: Entry, *, server_id: str, enable: bool) -> list[Edit]:
    return library_mapping_edits(
        run, entry, server_id=server_id, enable=enable
    ) + user_mapping_edits(run, entry, server_id=server_id, enable=enable)


def library_mapping_edits(run: Run, entry: Entry, *, server_id: str, enable: bool) -> list[Edit]:
    libraries = [lib for lib in run.spec.libraries if lib.key in run.library_ids]
    if not libraries:
        return []
    answer = run.api.request(
        "POST", "/Sync/GetSourceLibraries", entry.peer_request(), timeout=PEER_TIMEOUT
    )
    sources = {text(lib, "Name"): lib for lib in map(as_object, as_list(answer))}
    edit_list: list[Edit] = []
    for lib in libraries:
        source = sources.get(lib.name)
        if source is None:
            run.note(
                "setup-source-library-missing",
                f"Library {lib.name}",
                "the source has no library by that name that the sync account can see.",
                f"Run `sudo sea-nettle setup` on the source; {RERUN}.",
            )
            continue
        locations = [edits.strip_slash(str(p)) for p in as_list(source.get("Locations"))]
        # A limited account's view of the source omits folder paths.
        if locations and lib.source_path not in locations:
            run.note(
                "conflict-source-library-path",
                f"Library {lib.name}",
                f"the source's library does not include {lib.source_path}.",
                f"Correct the spec's sourcePath, or the library on the source; {RERUN}.",
            )
            continue
        source_id = text(source, "Id")
        whitelist, complete = resolve_whitelist(run, entry, lib, source_library_id=source_id)
        edit_list.append(
            edits.library_mapping(
                server_id,
                edits.LibraryMappingWant(
                    library=lib.name,
                    source_library_id=source_id,
                    source_library_name=text(source, "Name"),
                    source_path=lib.source_path,
                    local_library_id=run.library_ids[lib.key],
                    local_library_name=lib.name,
                    local_path=run.library_path(lib),
                    whitelist=whitelist,
                    complete=complete,
                ),
                enable=enable,
            )
        )
    return edit_list


def user_mapping_edits(run: Run, entry: Entry, *, server_id: str, enable: bool) -> list[Edit]:
    """Maps each spec user to their Peer Login account, when the source account is an
    administrator. Its key streams links as the user the replica maps, so an unmapped
    user cannot stream; a limited key streams only as itself and needs no mappings."""
    if not run.spec.users or not run.spec.source.sync_account.administrator:
        return []
    answer = run.api.request(
        "POST", "/Sync/GetSourceUsers", entry.peer_request(), timeout=PEER_TIMEOUT
    )
    source_users = {text(u, "Name").lower(): u for u in map(as_object, as_list(answer))}
    local_users = run.users()
    edit_list: list[Edit] = []
    for person in run.spec.users:
        source_user = source_users.get(person.name.lower())
        local = local_users.get(person.name.lower())
        if source_user is None:
            run.note(
                "setup-source-user-missing",
                f"User {person.name}",
                "the source has no such user.",
                f"Run `sudo sea-nettle setup` on the source; {RERUN}.",
            )
            continue
        if local is None:
            # Peer Login creates the replica user at their first sign-in.
            run.waiting.append(
                Attention(
                    code="setup-user-deferred",
                    subject=f"User {person.name}",
                    problem="they have not signed in to the replica yet, so they cannot be "
                    "mapped.",
                    fix=f"After {person.name} signs in to the replica with their source "
                    f"password, {RERUN}.",
                )
            )
            continue
        provider = text(as_object(local.get("Policy") or {}), "AuthenticationProviderId")
        if provider != PEER_LOGIN_PROVIDER:
            # The replica's local accounts stay separate from source users (R-LOGIN-9).
            run.note(
                "conflict-local-user",
                f"User {person.name}",
                "the replica's user by that name is a local account, not a Peer Login user.",
                f"Rename or remove the replica's account under {USERS}, or remove "
                f"{person.name} from the spec's users; {RERUN}.",
            )
            continue
        edit_list.append(
            edits.user_mapping(
                server_id,
                edits.UserMappingWant(
                    source_user_id=text(source_user, "Id"),
                    source_name=text(source_user, "Name"),
                    local_user_id=text(local, "Id"),
                    local_name=text(local, "Name"),
                ),
                enable=enable,
            )
        )
    return edit_list


def resolve_whitelist(
    run: Run, entry: Entry, lib: Library, *, source_library_id: str
) -> tuple[tuple[JsonObject, ...] | None, bool]:
    """Server Sync's FilteredItems for the spec's whitelist, and whether all were found."""
    if isinstance(lib.content, AllContent):
        return None, True
    items: list[JsonObject] = []
    while True:
        query = urllib.parse.urlencode(
            {
                "libraryId": source_library_id,
                "serverKey": entry.key,
                "startIndex": len(items),
                "limit": 200,
            }
        )
        page = as_object(
            run.api.request("GET", f"/Sync/SourceLibraryItems?{query}", timeout=PEER_TIMEOUT)
        )
        batch = [as_object(i) for i in as_list(page.get("Items"))]
        items += batch
        total = page.get("TotalCount")
        if not batch or (isinstance(total, int) and len(items) >= total):
            break
    filtered, missing = whitelist_items(items, lib.whitelist_paths())
    if missing:
        run.note(
            "setup-whitelist-missing",
            f"Library {lib.name}",
            f"the source has no top-level items at {', '.join(missing)}, so the mapping stays "
            "disabled.",
            "Check the spec's whitelist paths, and that the source has scanned the library; "
            f"{RERUN}.",
        )
    return filtered, not missing


def whitelist_items(
    items: list[JsonObject], paths: tuple[str, ...]
) -> tuple[tuple[JsonObject, ...], list[str]]:
    """The source's top-level items at or inside each path, and the paths with none.

    A movie's path is its video file, inside the movie's folder; a show's is its folder.
    Server Sync finds a whitelist's content by item ID, and matches hints by path.
    """
    filtered: list[JsonObject] = []
    missing: list[str] = []
    for wanted in paths:
        matches = [
            i
            for i in items
            if (path := edits.strip_slash(text(i, "Path"))) == wanted
            or path.startswith(wanted + "/")
        ]
        if not matches:
            missing.append(wanted)
        filtered += [
            {
                "ItemId": text(i, "Id"),
                "Name": text(i, "Name"),
                "Year": i.get("Year"),
                "Path": edits.strip_slash(text(i, "Path")),
                "Type": i.get("Type"),
            }
            for i in matches
        ]
    return tuple(filtered), missing


def setup(api: Jellyfin, spec: Spec, *, role: Role, replica_root: Path | None) -> Outcome:
    plugin = Plugin.find(api.get("/Plugins"), SERVER_SYNC_ID)
    if plugin is None or plugin.status != "Active":
        raise Fatal("Server Sync is not active here; run `sudo sea-nettle status` for the fix.")
    run = Run(api, spec, role=role, replica_root=replica_root)
    try:
        run_setup(run)
    except Fatal as e:
        message = str(e)
        if isinstance(e, HttpStatus):
            message += f" Nothing after that call was changed; {RERUN}."
        done = run.outcome().changes
        if done:
            message += "\nChanged before the failure:\n" + "\n".join(f"- {c}" for c in done)
        raise Fatal(message) from None
    return run.outcome()
