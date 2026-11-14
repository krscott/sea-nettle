# R-PAIR-3, R-PAIR-4: sign-in failures, unanswered calls, and sign-out, against a stub Jellyfin.
from __future__ import annotations

import json
import signal
import socket
import threading
import time
from collections.abc import Callable, Generator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from sea_nettle.__main__ import main
from sea_nettle.jellyfin import Fatal, Jellyfin, Unanswered, signed_in

ADMIN = {"AccessToken": "token-1", "User": {"Policy": {"IsAdministrator": True}}}
CONFIG_PATH = "/Plugins/ebd650b5-6f4c-4ccb-b10d-23dffb3a7286/Configuration"


@dataclass
class Stub:
    """Answers by method and path; records the calls it got."""

    answers: dict[str, tuple[int, object]] = field(default_factory=dict[str, tuple[int, object]])
    delay: float = 0
    calls: list[str] = field(default_factory=list[str])
    on_call: Callable[[str], None] = lambda call: None


def handler(stub: Stub) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def _answer(self) -> None:
            call = f"{self.command} {self.path}"
            stub.calls.append(call)
            stub.on_call(call)
            if stub.delay:
                time.sleep(stub.delay)
            status, body = stub.answers.get(call, (404, None))
            content = b"" if body is None else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        do_GET = _answer
        do_POST = _answer

        def log_message(self, format: str, *args: object) -> None:
            pass

    return Handler


@pytest.fixture
def stub() -> Generator[tuple[Stub, str]]:
    state = Stub()
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield state, f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()
    server.server_close()


@pytest.fixture
def password_file(tmp_path: Path) -> Path:
    path = tmp_path / "password"
    path.write_text("admin-pw\n")
    return path


def sign_in(url: str, password_file: Path) -> None:
    with signed_in(url, name="admin", password_file=password_file):
        pass


def test_wrong_password_names_the_password_file(
    stub: tuple[Stub, str], password_file: Path
) -> None:
    state, url = stub
    state.answers["POST /Users/AuthenticateByName"] = (401, None)
    with pytest.raises(Fatal, match="refused the sign-in as admin.*update .*password"):
        sign_in(url, password_file)


def test_disabled_account_says_how_to_enable_it(
    stub: tuple[Stub, str], password_file: Path
) -> None:
    state, url = stub
    state.answers["POST /Users/AuthenticateByName"] = (403, None)
    with pytest.raises(Fatal, match="disabled.*Dashboard > Users"):
        sign_in(url, password_file)


def test_unreachable_jellyfin(password_file: Path) -> None:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        closed_port = s.getsockname()[1]
    with pytest.raises(Fatal, match="Cannot reach Jellyfin.*systemctl status"):
        sign_in(f"http://127.0.0.1:{closed_port}", password_file)


def test_starting_jellyfin_gets_the_systemctl_hint(
    stub: tuple[Stub, str], password_file: Path
) -> None:
    state, url = stub
    state.answers["POST /Users/AuthenticateByName"] = (503, None)
    with pytest.raises(Fatal, match="HTTP 503.*systemctl status"):
        sign_in(url, password_file)


def test_unanswered_call(stub: tuple[Stub, str]) -> None:
    state, url = stub
    state.delay = 1
    with pytest.raises(Unanswered, match="did not answer GET /System/Info"):
        Jellyfin(url, token="t").request("GET", "/System/Info", timeout=0.2)


def test_session_ends_after_a_failure(stub: tuple[Stub, str], password_file: Path) -> None:
    state, url = stub
    state.answers["POST /Users/AuthenticateByName"] = (200, ADMIN)
    state.answers["POST /Sessions/Logout"] = (204, None)
    with pytest.raises(Fatal), signed_in(url, name="admin", password_file=password_file):
        raise Fatal("collect failed")
    assert state.calls[-1] == "POST /Sessions/Logout"


def test_revoked_token_counts_as_signed_out(
    stub: tuple[Stub, str], password_file: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    state, url = stub
    state.answers["POST /Users/AuthenticateByName"] = (200, ADMIN)
    # A later run's sign-in revoked this run's token, or the account was disabled.
    state.answers["POST /Sessions/Logout"] = (401, None)
    with signed_in(url, name="admin", password_file=password_file) as api:
        pass
    assert api.signed_out
    assert "If the account was disabled" in capsys.readouterr().err


def run_status(url: str, password_file: Path) -> int:
    return main(
        [
            "--url",
            url,
            "--admin-name",
            "admin",
            "--password-file",
            str(password_file),
            "--server-sync-version",
            "12.2.11.4",
            "status",
            "--json",
        ]
    )


def healthy(state: Stub) -> None:
    state.answers.update(
        {
            "POST /Users/AuthenticateByName": (200, ADMIN),
            "GET /System/Info": (200, {"ServerName": "source"}),
            "GET /Users": (200, []),
            "GET /Library/VirtualFolders": (200, []),
            "POST /Sessions/Logout": (204, None),
        }
    )
    state.answers["GET /Plugins"] = (
        200,
        [{"Id": "ebd650b56f4c4ccbb10d23dffb3a7286", "Version": "12.2.11.4", "Status": "Active"}],
    )
    state.answers[f"GET {CONFIG_PATH}"] = (
        200,
        {"Servers": [{"Key": "e1", "Name": "replica", "Url": "https://replica", "ApiKey": "x"}]},
    )
    state.answers["POST /Sync/Hints/CheckPeer"] = (
        200,
        {
            "Reachable": True,
            "PeerMode": "Push",
            "Paired": True,
            "Severity": "ok",
            "Message": "Ready.",
        },
    )


def test_status_reports_attention_and_signs_out(
    stub: tuple[Stub, str], password_file: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    state, url = stub
    healthy(state)
    # The entry records no server ID.
    assert run_status(url, password_file) == 3
    report = json.loads(capsys.readouterr().out)
    assert [a["code"] for a in report["attention"]] == ["entry-no-server-id"]
    assert state.calls[-1] == "POST /Sessions/Logout"


def test_failed_sign_out_fails_the_run(
    stub: tuple[Stub, str], password_file: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    state, url = stub
    healthy(state)
    state.answers["POST /Sessions/Logout"] = (500, None)
    assert run_status(url, password_file) == 1
    captured = capsys.readouterr()
    # The report still prints; the error says how to end the session.
    assert json.loads(captured.out)["attention"]
    assert 'Remove the "sea-nettle" device under Dashboard > Devices' in captured.err


def test_sigterm_signs_out(stub: tuple[Stub, str], password_file: Path) -> None:
    state, url = stub
    healthy(state)
    main_thread = threading.get_ident()
    state.on_call = lambda call: (
        signal.pthread_kill(main_thread, signal.SIGTERM) if call == "GET /Users" else None
    )
    previous = signal.getsignal(signal.SIGTERM)
    try:
        with pytest.raises(SystemExit) as exit_info:
            run_status(url, password_file)
    finally:
        signal.signal(signal.SIGTERM, previous)
    assert exit_info.value.code == 128 + signal.SIGTERM
    assert state.calls[-1] == "POST /Sessions/Logout"


def test_local_http_error_is_one_line(
    stub: tuple[Stub, str], password_file: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    state, url = stub
    healthy(state)
    state.answers["POST /Sync/Hints/CheckPeer"] = (401, None)
    assert run_status(url, password_file) == 1
    err = capsys.readouterr().err
    assert "Jellyfin answered POST /Sync/Hints/CheckPeer with HTTP 401" in err
    assert "Traceback" not in err
    assert state.calls[-1] == "POST /Sessions/Logout"
