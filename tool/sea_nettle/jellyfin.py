"""A minimal client for the local Jellyfin API, signed in as its administrator."""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path

from .model import as_object, flag, text

CLIENT = "sea-nettle"
VERSION = "0.1.0"
# A fixed device: signing in again revokes the token of an earlier run that could not sign out.
DEVICE_ID = "sea-nettle"


class Fatal(Exception):
    """An expected failure, reported as its message without a traceback."""


class Jellyfin:
    def __init__(self, url: str, *, token: str | None = None) -> None:
        self.url = url.rstrip("/")
        self._token = token

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
        """The parsed JSON answer, or None for an empty one. HTTP errors raise."""
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, method=method)
        request.add_header("Authorization", self._authorization())
        if data is not None:
            request.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            content = response.read()
        return json.loads(content) if content.strip() else None

    def get(self, path: str) -> object:
        return self.request("GET", path)


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


@contextmanager
def signed_in(url: str, *, name: str, password_file: Path) -> Generator[Jellyfin]:
    """Signs in as the administrator, and always ends the session (R-PAIR-3)."""
    password = read_password(password_file)
    anonymous = Jellyfin(url)
    try:
        answer = as_object(
            anonymous.request(
                "POST", "/Users/AuthenticateByName", {"Username": name, "Pw": password}
            )
        )
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise Fatal(
                f"Jellyfin refused the sign-in as {name}. If its password was changed in "
                f"the dashboard after setup, update {password_file} to match."
            ) from None
        raise
    except urllib.error.URLError as e:
        raise Fatal(
            f"Cannot reach Jellyfin at {url}: {e.reason}. "
            "Check `systemctl status jellyfin.service`."
        ) from None

    api = Jellyfin(url, token=text(answer, "AccessToken"))
    try:
        policy = as_object(as_object(answer.get("User")).get("Policy"))
        if not flag(policy, "IsAdministrator", default=False):
            raise Fatal(f"{name} is not an administrator on this server.")
        yield api
    finally:
        try:
            api.request("POST", "/Sessions/Logout")
        except urllib.error.URLError as e:
            print(
                f"sea-nettle: could not sign out of Jellyfin ({e}). Remove the "
                f'"{CLIENT}" device under Dashboard > Devices.',
                file=sys.stderr,
            )
