"""Command line entry point.

Exit status: 0 when nothing needs attention, 3 when the report lists something that
does, 1 when the command fails, and 2 for usage errors.
"""

from __future__ import annotations

import argparse
import json
import signal
import sys
from pathlib import Path
from types import FrameType

from .jellyfin import Fatal, signed_in
from .report import Attention, build
from .setup import setup
from .spec import Spec, parse
from .status import collect

NEEDS_ATTENTION = 3


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sea-nettle",
        description="Set up and check this server's Server Sync pair. The NixOS module's "
        "wrapper passes the server options.",
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
    p.add_argument("--spec", type=Path, help="setup specification (JSON), for setup")
    p.add_argument(
        "--role", choices=["source", "replica"], help="this server's role in the spec, for setup"
    )
    p.add_argument(
        "--replica-root", type=Path, help="folder that holds the replica's libraries, for setup"
    )
    commands = p.add_subparsers(dest="command", required=True)
    status = commands.add_parser(
        "status",
        help="report what needs attention; never changes configuration",
        description="Report this server's Server Sync peers, run Server Sync's link check "
        "to each, and list what needs attention. Link checks can renew pairing secrets.",
    )
    status.add_argument("--json", action="store_true", help="print the report as JSON")
    setup_command = commands.add_parser(
        "setup",
        help="set up this server's side of the spec, then report like status",
        description="Create what the spec asks for on this server and enable its mappings "
        "once the link check passes. Never removes, disables, or rewrites existing "
        "configuration. Run it on both servers until neither reports anything.",
    )
    setup_command.add_argument("--json", action="store_true", help="print the report as JSON")
    return p


def _exit_on_sigterm(signum: int, frame: FrameType | None) -> None:
    raise SystemExit(128 + signum)


def load_spec(args: argparse.Namespace) -> Spec | str:
    """The validated spec, or why there is none (R-PAIR-5)."""
    if args.spec is None or args.role is None:
        return "setup needs --spec and --role; set sea-nettle.jellyfin.setup in the NixOS module."
    if args.role == "replica" and args.replica_root is None:
        return "setup on a replica needs --replica-root."
    try:
        value: object = json.loads(args.spec.read_text(encoding="utf-8"))
    except OSError as e:
        return f"Cannot read the spec {args.spec}: {e.strerror}."
    except json.JSONDecodeError as e:
        return f"The spec {args.spec} is not valid JSON: {e}."
    spec = parse(value, role=args.role, admin_name=args.admin_name)
    if isinstance(spec, list):
        problems = "\n".join(f"- {p}" for p in spec)
        return f"The spec {args.spec} is invalid; nothing was changed:\n{problems}"
    return spec


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    spec = None
    if args.command == "setup":
        loaded = load_spec(args)
        if isinstance(loaded, str):
            print(f"sea-nettle: {loaded}", file=sys.stderr)
            return 1
        spec = loaded
    # SIGTERM ends the run the way Ctrl-C does, through the sign-out (R-PAIR-3).
    signal.signal(signal.SIGTERM, _exit_on_sigterm)
    changes: tuple[str, ...] = ()
    waiting: tuple[Attention, ...] = ()
    try:
        with signed_in(args.url, name=args.admin_name, password_file=args.password_file) as api:
            if spec is not None:
                outcome = setup(api, spec, role=args.role, replica_root=args.replica_root)
                changes = outcome.changes
                attention = outcome.attention
                waiting = outcome.waiting
            else:
                attention = ()
            snapshot = collect(api)
    except Fatal as e:
        print(f"sea-nettle: {e}", file=sys.stderr)
        return 1
    report = build(
        snapshot,
        expected_version=args.server_sync_version,
        changes=changes,
        attention=attention,
        waiting=waiting,
    )
    sys.stdout.write(report.to_json() + "\n" if args.json else report.to_text())
    if not api.signed_out:
        # R-PAIR-3; signed_in has said how to end the session.
        return 1
    return NEEDS_ATTENTION if report.attention else 0


def run() -> None:
    sys.exit(main())


if __name__ == "__main__":
    run()
