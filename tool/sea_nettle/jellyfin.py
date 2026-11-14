"""A minimal client for the local Jellyfin API, signed in as its administrator."""

from __future__ import annotations

import http.client
import json
import re
import signal
import sys
import urllib.error
import urllib.request
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from types import FrameType

from .model import as_object, flag, text

CLIENT = "sea-nettle"
VERSION = "0.1.0"
# A fixed device: a successful sign-in revokes the token of an earlier run that could not
# sign out, or of a run still going on the same host.
DEVICE_ID = "sea-nettle"


class Fatal(Exception):
    """An expected failure, reported as its message without a traceback."""


class HttpStatus(Fatal):
    def __init__(self, message: str, *, status: int) -> None:
        super().__init__(message)
        self.status = status


class Jellyfin:
    def __init__(self, url: str, *, token: str | None = None) -> None:
        self.url = url.rstrip("/")
        self._token = token
        # Whether the session this client holds has ended.
        self.signed_out = token is None

    def _authorization(self) -> str:
        value = (
            f'MediaBrowser Client="{CLIENT}", Device="{CLIENT}", '
            f'DeviceId="{DEVICE_ID}", Version="{VERSION}"'
        )
        if self._token:
            value += f', Token="{self._token}"'
        return value

    def request(
        self, method: str, path: str, body: object = None, *, timeout: float = 30
    ) -> object:
        """The parsed JSON answer, or None for an empty one.

        Raises `HttpStatus` for an HTTP error, and `Fatal` when Jellyfin cannot be reached
        or does not answer in time.
        """
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, method=method)
        request.add_header("Authorization", self._authorization())
        if data is not None:
            request.add_header("Content-Type", "application/json")
        call = f"{method} {path.split('?')[0]}"
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                content = response.read()
        except urllib.error.HTTPError as e:
            raise HttpStatus(
                f"Jellyfin answered {call} with HTTP {e.code} {e.reason}.", status=e.code
            ) from None
        except urllib.error.URLError as e:
            raise Fatal(f"Cannot reach Jellyfin at {self.url} for {call}: {e.reason}.") from None
        except (TimeoutError, http.client.HTTPException, ConnectionError) as e:
            raise Fatal(f"Jellyfin did not answer {call}: {str(e) or type(e).__name__}.") from None
        return json.loads(content) if content.strip() else None

    def get(self, path: str) -> object:
        return self.request("GET", path)

    def sign_out(self) -> None:
        """Ends the session; on failure, says how to end it and leaves `signed_out` false."""
        try:
            self.request("POST", "/Sessions/Logout")
        except HttpStatus as e:
            if e.status != 401:
                self._report_sign_out_failure(e)
                return
            # A later run's sign-in has already revoked this token.
        except Fatal as e:
            self._report_sign_out_failure(e)
            return
        self.signed_out = True

    @staticmethod
    def _report_sign_out_failure(e: Fatal) -> None:
        print(
            f"sea-nettle: could not sign out of Jellyfin: {e} Remove the "
            f'"{CLIENT}" device under Dashboard > Devices.',
            file=sys.stderr,
        )


def read_password(path: Path) -> str:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError as e:
        raise Fatal(
            f"Cannot read the administrator password file {path}: {e.strerror}. "
            "It is usually readable by root only; run sea-nettle with sudo."
        ) from e
    # The same rule as jellyfin-initial-admin, which set the password from this file.
    password = re.sub(r"\n+$", "", content)
    if not password:
        raise Fatal(f"The administrator password file {path} is empty.")
    return password


class _Termination:
    """Turns SIGTERM and SIGHUP into SystemExit, so `finally` blocks run, or defers them."""

    def __init__(self) -> None:
        self.deferring = False
        self.pending: int | None = None

    def __call__(self, signum: int, frame: FrameType | None) -> None:
        if not self.deferring:
            raise SystemExit(128 + signum)
        if self.pending is None:
            self.pending = signum


@contextmanager
def signed_in(url: str, *, name: str, password_file: Path) -> Generator[Jellyfin]:
    """Signs in as the administrator, and ends the session even on failure (R-PAIR-3).

    A failed sign-out leaves the yielded client's `signed_out` false.
    """
    password = read_password(password_file)
    try:
        answer = as_object(
            Jellyfin(url).request(
                "POST", "/Users/AuthenticateByName", {"Username": name, "Pw": password}
            )
        )
    except HttpStatus as e:
        if e.status == 401:
            raise Fatal(
                f"Jellyfin refused the sign-in as {name}. If its password was changed in "
                f"the dashboard after setup, update {password_file} to match."
            ) from None
        if e.status == 403:
            raise Fatal(
                f"Jellyfin refused the sign-in as {name} with HTTP 403: the account is "
                "disabled, possibly locked out after failed sign-ins. Enable it under "
                f"Dashboard > Users, and check that {password_file} holds its password."
            ) from None
        raise Fatal(f"{e} Check `systemctl status jellyfin.service`.") from None
    except Fatal as e:
        raise Fatal(f"{e} Check `systemctl status jellyfin.service`.") from None

    api = Jellyfin(url, token=text(answer, "AccessToken"))
    # Termination signals run the sign-out below instead of skipping it. An ignored signal,
    # as under nohup, stays ignored.
    termination = _Termination()
    previous = {
        s: signal.signal(s, termination)
        for s in (signal.SIGTERM, signal.SIGHUP)
        if signal.getsignal(s) == signal.SIG_DFL
    }
    try:
        policy = as_object(as_object(answer.get("User")).get("Policy"))
        if not flag(policy, "IsAdministrator", default=False):
            raise Fatal(f"{name} is not an administrator on this server.")
        yield api
    finally:
        termination.deferring = True
        try:
            api.sign_out()
        finally:
            for s, handler in previous.items():
                signal.signal(s, handler)
        if termination.pending is not None:
            raise SystemExit(128 + termination.pending)
