# R-PAIR-5: the spec is checked as a whole before setup changes anything.
from __future__ import annotations

import copy

from sea_nettle.model import as_list
from sea_nettle.spec import AllContent, Spec, Whitelist, parse

SPEC: dict[str, object] = {
    "source": {
        "url": "https://source.example.ts.net:8445/",
        "syncAccount": {
            "name": "replica-sync",
            "passwordFile": "/run/secrets/replica-sync",
            "administrator": True,
        },
    },
    "replica": {
        "url": "https://replica.example.ts.net:8445",
        "syncAccount": {
            "name": "source-sync",
            "passwordFile": "/run/secrets/source-sync",
            "administrator": False,
        },
    },
    "libraries": [
        {
            "key": "movies",
            "name": "Movies",
            "type": "movies",
            "sourcePath": "/srv/media/movies",
            "content": {"whitelist": ["Big Buck Bunny (2008)"]},
        },
        {
            "key": "shows",
            "name": "Shows",
            "type": "tvshows",
            "sourcePath": "/srv/media/shows",
            "content": "all",
        },
    ],
    "users": [
        {"name": "alice", "passwordFile": "/run/secrets/alice", "syncHistory": True},
        {"name": "bob", "passwordFile": None, "syncHistory": False},
    ],
}


def spec(**changes: object) -> dict[str, object]:
    value = copy.deepcopy(SPEC)
    value.update(changes)
    return value


def errors(value: object, *, role: str = "source") -> list[str]:
    result = parse(value, role="source" if role == "source" else "replica", admin_name="admin")
    assert isinstance(result, list), result
    return result


def test_parses_a_complete_spec() -> None:
    result = parse(SPEC, role="source", admin_name="admin")
    assert isinstance(result, Spec), result
    assert result.source.url == "https://source.example.ts.net:8445"
    assert result.libraries[0].content == Whitelist(paths=("Big Buck Bunny (2008)",))
    assert result.libraries[0].whitelist_paths() == ("/srv/media/movies/Big Buck Bunny (2008)",)
    assert result.libraries[1].content == AllContent()
    assert result.users[1].password_file is None


def test_history_for_other_users_needs_an_administrator_source_account() -> None:
    value = spec()
    source = value["source"]
    assert isinstance(source, dict)
    source["syncAccount"]["administrator"] = False
    [problem] = errors(value)
    assert "syncHistory for alice needs source.syncAccount.administrator = true" in problem


def test_reports_every_problem_at_once() -> None:
    value = spec(
        libraries=[
            {"key": "a b", "name": "Movies", "type": "film", "sourcePath": "srv/", "content": 1},
            {"key": "x", "name": "movies", "type": "movies", "sourcePath": "/m", "content": "all"},
        ],
        users=[{"name": " alice", "syncHistory": "yes"}],
        extra=True,
    )
    found = "\n".join(errors(value))
    for expected in [
        'spec: unknown field "extra"',
        'libraries[0]: "key" may hold only',
        'libraries[0]: "type" must be one of',
        'libraries[0]: "sourcePath" must be an absolute path',
        'libraries[0]: "content" must be "all"',
        'libraries: name "movies" is used twice',
        'users[0]: " alice" is not a valid Jellyfin user name',
        'users[0]: "syncHistory" must be true or false',
    ]:
        assert expected in found, found


def test_refuses_plain_http_to_another_host() -> None:
    value = spec()
    source = value["source"]
    assert isinstance(source, dict)
    source["url"] = "http://source:8096"
    assert errors(value) == ['source: "url" must use HTTPS unless it is a loopback address']


def test_refuses_a_whitelist_path_outside_the_library() -> None:
    value = spec()
    libraries = value["libraries"]
    assert isinstance(libraries, list)
    libraries[0]["content"] = {"whitelist": ["../other"]}
    assert errors(value) == [
        'libraries[0]: whitelist item "../other" must be a path relative to sourcePath'
    ]


def test_sync_accounts_are_dedicated() -> None:
    value = spec()
    replica = value["replica"]
    assert isinstance(replica, dict)
    replica["syncAccount"]["name"] = "Admin"
    as_list(value["users"]).append(
        {"name": "replica-sync", "passwordFile": None, "syncHistory": False}
    )
    assert errors(value, role="replica") == [
        'source.syncAccount: "replica-sync" is also listed under users',
        'replica.syncAccount: "Admin" is this server\'s administrator; use a dedicated account',
    ]
