"""Command line entry point.

Exit status: 0 when nothing needs attention, 3 when the report lists something that
does, 1 when the command fails, and 2 for usage errors.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .jellyfin import Fatal, signed_in
from .report import build
from .status import collect

NEEDS_ATTENTION = 3


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sea-nettle",
        description="Check this server's Server Sync setup. The NixOS module's wrapper "
        "passes the server options.",
    )
    p.add_argument("--url", required=True, help="Jellyfin's loopback URL")
    p.add_argument("--admin-name", required=True, help="Jellyfin administrator to sign in as")
    p.add_argument(
        "--password-file",
        required=True,
        type=Path,
        help="file that holds the administrator's password",
    )
    p.add_argument(
        "--server-sync-version", required=True, help="Server Sync version this system pins"
    )
    commands = p.add_subparsers(dest="command", required=True)
    status = commands.add_parser(
        "status",
        help="report what needs attention; never changes configuration",
        description="Report this server's Server Sync peers, run Server Sync's link check "
        "to each, and list what needs attention. Link checks can renew pairing secrets.",
    )
    status.add_argument("--json", action="store_true", help="print the report as JSON")
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        with signed_in(args.url, name=args.admin_name, password_file=args.password_file) as api:
            snapshot = collect(api)
    except Fatal as e:
        print(f"sea-nettle: {e}", file=sys.stderr)
        return 1
    report = build(snapshot, expected_version=args.server_sync_version)
    sys.stdout.write(report.to_json() + "\n" if args.json else report.to_text())
    if not api.signed_out:
        # R-PAIR-3; signed_in has said how to end the session.
        return 1
    return NEEDS_ATTENTION if report.attention else 0


def run() -> None:
    sys.exit(main())


if __name__ == "__main__":
    run()
