# A source and a replica Jellyfin. Each serves HTTPS through nginx with a test certificate that
# the other trusts.
{ pkgs, ... }:

let
  certs = pkgs.runCommand "test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir "$out"
    for name in source replica; do
      openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=$name" \
        -addext "subjectAltName=DNS:$name" \
        -keyout "$out/$name.key" -out "$out/$name.crt"
    done
  '';

  # Two short videos for the source's media; the setup spec whitelists one.
  media = pkgs.runCommand "test-media" { nativeBuildInputs = [ pkgs.ffmpeg-headless ]; } ''
    mkdir "$out"
    for name in clip other; do
      ffmpeg -loglevel error -f lavfi -i testsrc=duration=3:size=160x120:rate=10 -c:v mpeg4 "$out/$name.mp4"
    done
  '';

  # The same spec on both servers; each `sea-nettle setup` run sets up its own side.
  setupSpec = {
    source = {
      url = "https://source";
      # An administrator, so the watch history of every mapped user syncs.
      syncAccount = {
        name = "replica-sync";
        passwordFile = "/run/replica-sync-password";
        administrator = true;
      };
    };
    replica = {
      url = "https://replica";
      syncAccount = {
        name = "source-sync";
        passwordFile = "/run/source-sync-password";
        administrator = false;
      };
    };
    libraries.movies = {
      name = "Movies";
      type = "movies";
      sourcePath = "/srv/media/movies";
      content.whitelist = [ "Clip (2020)" ];
    };
    # Every replica user is mapped: the source streams links only for mapped users.
    users = {
      alice = { };
      bob = { };
      source-admin = { };
      carol.passwordFile = "/run/carol-password";
    };
    syncHistory = true;
  };

  server = {
    # Jellyfin refuses to start with less than 2 GiB free in its data directory.
    virtualisation.diskSize = 4096;
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.util-linux ];
    # The test writes the password at runtime, so it never reaches the Nix store (R-SERVER-6).
    sea-nettle.jellyfin.initialAdmin.passwordFile = "/run/jellyfin-admin-password";
    sea-nettle.jellyfin.setup = setupSpec;
    security.pki.certificateFiles = [
      "${certs}/source.crt"
      "${certs}/replica.crt"
    ];
  };

  # nginx stands in for Tailscale Serve's HTTPS proxy.
  https = name: {
    services.nginx = {
      enable = true;
      virtualHosts.${name} = {
        onlySSL = true;
        sslCertificate = "${certs}/${name}.crt";
        sslCertificateKey = "${certs}/${name}.key";
        locations."/".proxyPass = "http://127.0.0.1:8096";
      };
    };
    networking.firewall.allowedTCPPorts = [ 443 ];
  };
in
{
  name = "replica-login";

  nodes.source =
    { lib, ... }:
    {
      imports = [
        server
        (https "source")
        ../modules/jellyfin.nix
        ../modules/server-sync.nix
      ];
      sea-nettle.jellyfin = {
        initialAdmin.name = "source-admin";
        mediaDirectory = "/srv/media";
        servePort = 8445;
      };
      systemd.tmpfiles.rules = [ "d /srv/media 0755 root root -" ];

      # Tailscale Serve needs a tailnet, so only its commands are stubbed; the unit keeps its
      # dependencies.
      services.tailscale.enable = true;
      systemd.services.jellyfin-serve.serviceConfig = {
        ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
        ExecStop = lib.mkForce "${pkgs.coreutils}/bin/true";
      };
    };

  nodes.replica = {
    imports = [
      server
      (https "replica")
      ../modules/replica.nix
    ];
    # Peer Login's source URL defaults to the setup spec's.
    sea-nettle.jellyfin.initialAdmin.name = "replica-admin";
    # The test re-runs activation (R-SERVER-2).
    system.switch.enable = true;
  };

  testScript = ''
    import hashlib
    import itertools
    import json
    import re
    import shlex
    import time

    PEER_LOGIN = "74c2e693-6ab7-40fa-858d-c752d48cb45c"
    SERVER_SYNC = "ebd650b5-6f4c-4ccb-b10d-23dffb3a7286"
    PEER_PROVIDER = "Jellyfin.Plugin.PeerLogin.PeerAuthenticationProvider"
    ADMIN_PASSWORD_FILE = "/run/jellyfin-admin-password"
    # Password files the setup spec names.
    PASSWORDS = {
        "/run/replica-sync-password": "replica-sync-pw",
        "/run/source-sync-password": "source-sync-pw",
        "/run/carol-password": "carol-1",
    }


    # Jellyfin revokes a user's earlier token when they sign in again from the same device.
    device_ids = itertools.count()


    def api(machine, method, path, body=None, token=None, expect=200, device="vm-test", base="http://127.0.0.1:8096"):
        auth = f'MediaBrowser Client="VM Test", Device="vm", DeviceId="{device}", Version="1"'
        if token:
            auth += f', Token="{token}"'
        cmd = (
            f"curl -sS -o /tmp/body -w '%{{http_code}}' -X {method}"
            f" {shlex.quote(base + path)} -H {shlex.quote('Authorization: ' + auth)}"
        )
        if body is not None:
            cmd += f" -H 'Content-Type: application/json' --data-binary {shlex.quote(json.dumps(body))}"
        status = int(machine.succeed(cmd))
        text = machine.succeed("cat /tmp/body")
        assert status == expect, f"{machine.name} {method} {path}: expected {expect}, got {status}: {text}"
        # Error responses are plain text.
        return json.loads(text) if status < 300 and text.strip() else None


    def sign_in(machine, username, password, expect=200):
        result = api(
            machine,
            "POST",
            "/Users/AuthenticateByName",
            {"Username": username, "Pw": password},
            expect=expect,
            device=f"vm-test-{next(device_ids)}",
        )
        return result["AccessToken"] if expect == 200 else None


    def wait_for_jellyfin(machine):
        machine.wait_for_unit("jellyfin.service")
        machine.wait_for_open_port(8096)
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:8096/health | grep Healthy")


    def restart_jellyfin(machine):
        machine.succeed("systemctl restart jellyfin.service")
        wait_for_jellyfin(machine)


    def write_secret(machine, path, password):
        machine.succeed(f"(umask 077; printf '%s\\n' {shlex.quote(password)} >{path})")


    def write_admin_password(machine, password):
        write_secret(machine, ADMIN_PASSWORD_FILE, password)


    def wizard_completed(machine):
        return api(machine, "GET", "/System/Info/Public")["StartupWizardCompleted"]


    def unit_time(machine, unit, prop):
        return int(machine.succeed(f"systemctl show -P {prop} {unit}"))


    def admin_log(machine):
        return machine.succeed("journalctl -b -o cat -u jellyfin-initial-admin.service")


    def source_user_id(name):
        return next(u["Id"] for u in api(source, "GET", "/Users", token=source_admin) if u["Name"] == name)


    def replica_user(name):
        return next(u for u in api(replica, "GET", "/Users", token=replica_admin) if u["Name"] == name)


    def plugin(machine, token, plugin_id):
        return next(p for p in api(machine, "GET", "/Plugins", token=token) if p["Id"].replace("-", "") == plugin_id.replace("-", ""))


    def server_sync_config(machine, token):
        return api(machine, "GET", f"/Plugins/{SERVER_SYNC}/Configuration", token=token)


    def edit_server_sync_config(machine, token, edit):
        # Posts stored keys back as read, encrypted; Server Sync keeps them while URLs are unchanged.
        config = server_sync_config(machine, token)
        edit(config)
        api(machine, "POST", f"/Plugins/{SERVER_SYNC}/Configuration", config, token=token, expect=204)


    def set_entry(machine, token, **fields):
        edit_server_sync_config(machine, token, lambda c: c["Servers"][0].update(fields))


    def set_mapping(machine, token, **fields):
        edit_server_sync_config(machine, token, lambda c: c["Servers"][0]["LibraryMappings"][0].update(fields))


    def stable_server_sync_config(machine, token):
        # Server Sync's tasks stamp their last run times.
        return {k: v for k, v in server_sync_config(machine, token).items() if not k.startswith("Last")}


    def configuration(machine, token):
        """What `sea-nettle status`, and a `sea-nettle setup` with nothing to do, leave unchanged
        (R-PAIR-1, R-PAIR-6)."""
        active = plugin(machine, token, SERVER_SYNC)["Status"] == "Active"
        # Jellyfin's sign-in bookkeeping: every sign-in, including the command's own, updates
        # these, and a failed one counts toward lockout.
        users = []
        for user in api(machine, "GET", "/Users", token=token):
            user = {k: v for k, v in user.items() if k not in ("LastLoginDate", "LastActivityDate")}
            user["Policy"] = {k: v for k, v in user["Policy"].items() if k != "InvalidLoginAttemptCount"}
            users.append(user)
        return (
            stable_server_sync_config(machine, token) if active else None,
            users,
            api(machine, "GET", "/Library/VirtualFolders", token=token),
        )


    # Everything the commands printed, for R-PAIR-2.
    outputs = []


    def no_own_session(machine, token):
        """R-PAIR-3: the run's own session has ended."""
        devices = api(machine, "GET", "/Devices", token=token)["Items"]
        assert not [d for d in devices if d.get("AppName") == "sea-nettle"], devices
        sessions = api(machine, "GET", "/Sessions", token=token)
        assert not [s for s in sessions if s.get("Client") == "sea-nettle"], sessions


    def status(machine, token, expect, text=False):
        """Runs `sea-nettle status` and returns its output; checks R-PAIR-1 and R-PAIR-3 around every run."""
        before = configuration(machine, token)
        flags = "" if text else " --json"
        code, out = machine.execute(f"sea-nettle status{flags} 2>/tmp/status-stderr")
        err = machine.succeed("cat /tmp/status-stderr")
        outputs.append(out + err)
        assert code == expect, f"{machine.name}: status exited {code}, expected {expect}: {out}{err}"
        assert configuration(machine, token) == before, f"{machine.name}: status changed the configuration"
        no_own_session(machine, token)
        if text or code not in (0, 3):
            # A failed run prints its error to stderr.
            return out + err
        return json.loads(out)


    def attention(machine, token, expect):
        """The attention codes of a status report."""
        return codes(status(machine, token, expect))


    def codes(report):
        return sorted(a["code"] for a in report["attention"])


    def setup(machine, token, expect, command="sea-nettle setup --json"):
        """Runs `sea-nettle setup` and returns its report, or its output if it failed."""
        code, out = machine.execute(f"{command} 2>/tmp/setup-stderr")
        err = machine.succeed("cat /tmp/setup-stderr")
        outputs.append(out + err)
        assert code == expect, f"{machine.name}: setup exited {code}, expected {expect}: {out}{err}"
        no_own_session(machine, token)
        return json.loads(out) if code in (0, 3) else out + err


    def wait_for(condition, timeout=300):
        deadline = time.monotonic() + timeout
        while not condition():
            assert time.monotonic() < deadline, "timed out"
            time.sleep(2)


    def replica_entry():
        return server_sync_config(replica, replica_admin)["Servers"][0]


    def library(machine, token, name):
        return next(l for l in api(machine, "GET", "/Library/VirtualFolders", token=token) if l["Name"] == name)


    def movies(machine, token, library_id):
        return api(machine, "GET", f"/Items?ParentId={library_id}&Recursive=true&IncludeItemTypes=Movie", token=token)["Items"]


    start_all()
    wait_for_jellyfin(source)
    wait_for_jellyfin(replica)

    with subtest("R-SERVER-6: without its password file, a server stays unclaimed and unpublished"):
        for machine in [source, replica]:
            machine.wait_until_succeeds("systemctl is-failed jellyfin-initial-admin.service")
            log = admin_log(machine)
            assert "jellyfin-initial-admin.service: Failed to set up credentials: No such file or directory" in log, log
            assert not wizard_completed(machine)
        assert source.succeed("systemctl show -P ActiveState jellyfin-serve.service").strip() == "inactive"
        assert unit_time(source, "jellyfin-serve.service", "ExecMainStartTimestampMonotonic") == 0

    with subtest("R-SERVER-6: an interrupted setup is refused until Jellyfin restarts"):
        # Stands in for an earlier run that stopped before completing the wizard.
        api(source, "GET", "/Startup/User")
        api(source, "POST", "/Startup/User", {"Name": "source-admin", "Password": "admin-pw"}, expect=204)
        write_admin_password(source, "admin-pw")
        source.fail("systemctl start jellyfin-initial-admin.service")
        assert "first user already has a password" in admin_log(source)
        assert not wizard_completed(source)
        assert unit_time(source, "jellyfin-serve.service", "ExecMainStartTimestampMonotonic") == 0
        # The unit reads system.xml before Jellyfin's startup completes the wizard.
        source.succeed("systemctl restart jellyfin.service jellyfin-initial-admin.service")
        wait_for_jellyfin(source)
        assert wizard_completed(source)
        assert "system.xml now marks the startup wizard complete" in admin_log(source)
        source.succeed("systemctl start jellyfin-serve.service")
        source_admin = sign_in(source, "source-admin", "admin-pw")

    with subtest("R-SERVER-6: a new server gets the configured administrator"):
        write_admin_password(replica, "admin-pw")
        replica.succeed("systemctl start jellyfin-initial-admin.service")
        assert "Created the Jellyfin administrator replica-admin" in admin_log(replica)
        assert wizard_completed(replica)
        replica_admin = sign_in(replica, "replica-admin", "admin-pw")
        assert api(replica, "GET", "/Users/Me", token=replica_admin)["Policy"]["IsAdministrator"]

    with subtest("R-SERVER-6: restarting Jellyfin re-checks the administrator before Serve returns"):
        serve_before = unit_time(source, "jellyfin-serve.service", "ExecMainStartTimestampMonotonic")
        restart_jellyfin(source)
        source.wait_for_unit("jellyfin-serve.service")
        jellyfin_start = unit_time(source, "jellyfin.service", "ExecMainStartTimestampMonotonic")
        admin_done = unit_time(source, "jellyfin-initial-admin.service", "ActiveEnterTimestampMonotonic")
        serve_start = unit_time(source, "jellyfin-serve.service", "ExecMainStartTimestampMonotonic")
        assert serve_before < jellyfin_start < admin_done <= serve_start, (serve_before, jellyfin_start, admin_done, serve_start)
        assert "system.xml marks the startup wizard complete" in admin_log(source)
        source_admin = sign_in(source, "source-admin", "admin-pw")

    alice = api(source, "POST", "/Users/New", {"Name": "Alice", "Password": "alice-1"}, token=source_admin)
    api(source, "POST", "/Users/New", {"Name": "bob", "Password": "bob-1"}, token=source_admin)
    api(source, "POST", "/Users/New", {"Name": "replica-admin", "Password": "source-pw"}, token=source_admin)

    with subtest("R-LOGIN-1: the first sign-in creates the replica user"):
        sign_in(replica, "alice", "alice-1")
        user = replica_user("Alice")
        assert user["Policy"]["AuthenticationProviderId"] == PEER_PROVIDER, user["Policy"]

    with subtest("R-LOGIN-6: a source administrator is not a replica administrator"):
        sign_in(replica, "source-admin", "admin-pw")
        assert not replica_user("source-admin")["Policy"]["IsAdministrator"]

    with subtest("R-LOGIN-8: replica sign-ins leave no source session"):
        sessions = api(source, "GET", "/Sessions", token=source_admin)
        assert not [s for s in sessions if s.get("Client") == "Jellyfin Peer Login"], sessions
        devices = api(source, "GET", "/Devices", token=source_admin)["Items"]
        assert not [d for d in devices if d.get("AppName") == "Jellyfin Peer Login"], devices

    with subtest("R-LOGIN-9: a local replica account never uses source credentials"):
        sign_in(replica, "replica-admin", "source-pw", expect=401)
        sign_in(replica, "replica-admin", "admin-pw")

    with subtest("R-LOGIN-2: a source rejection overrides the cached password"):
        sign_in(replica, "alice", "wrong", expect=401)
        api(source, "POST", f"/Users/Password?userId={alice['Id']}", {"NewPw": "alice-2"}, token=source_admin, expect=204)
        sign_in(replica, "alice", "alice-1", expect=401)

    with subtest("R-LOGIN-3: a source-accepted password replaces the cached password"):
        alice_token = sign_in(replica, "alice", "alice-2")

    with subtest("R-LOGIN-5: the replica refuses password changes"):
        api(replica, "POST", "/Users/Password", {"CurrentPw": "alice-2", "NewPw": "alice-3"}, token=alice_token, expect=403)
        sign_in(replica, "alice", "alice-2")
        sign_in(replica, "alice", "alice-3", expect=401)

    with subtest("R-LOGIN-3, R-LOGIN-4: cached sign-in while the source is down"):
        source.succeed("systemctl stop jellyfin.service")
        sign_in(replica, "alice", "alice-2")
        sign_in(replica, "alice", "alice-1", expect=401)
        sign_in(replica, "bob", "bob-1", expect=401)
        sign_in(replica, "replica-admin", "admin-pw")
        source.succeed("systemctl stop nginx.service")
        sign_in(replica, "alice", "alice-2")
        sign_in(replica, "bob", "bob-1", expect=401)
        source.succeed("systemctl start nginx.service")
        source.succeed("systemctl start jellyfin.service")
        wait_for_jellyfin(source)
        sign_in(replica, "bob", "bob-1")

    with subtest("R-SERVER-1: Jellyfin listens only on localhost"):
        for machine in [source, replica]:
            listeners = machine.succeed("ss -Hlntup | grep '\"jellyfin\"' || true").strip().splitlines()
            assert listeners, f"{machine.name}: no Jellyfin listeners"
            for line in listeners:
                local = line.split()[4]
                assert local.startswith("127.0.0.1:"), f"{machine.name}: {line}"
        replica.fail("curl -sf --max-time 5 http://source:8096/health")
        replica.succeed("curl -sf --max-time 5 https://source/health")
        # The wizard's remote access step is skipped; proxied requests still work.
        api(replica, "GET", "/System/Info", token=source_admin, base="https://source")

    with subtest("R-SERVER-4: Jellyfin cannot modify the media directory"):
        pid = source.succeed("systemctl show -P MainPID jellyfin.service").strip()
        source.succeed(f"nsenter -t {pid} -m -- test -d /srv/media")
        source.fail(f"nsenter -t {pid} -m -- touch /srv/media/probe")
        source.succeed(f"nsenter -t {pid} -m -- touch /var/lib/jellyfin/probe")
        source.succeed("test ! -e /srv/media/probe")

    with subtest("R-SERVER-3: pinned plugins run at their pinned versions"):
        assert plugin(replica, replica_admin, PEER_LOGIN)["Version"] == "0.1.0.0"
        assert plugin(replica, replica_admin, PEER_LOGIN)["Status"] == "Active"
        server_sync = plugin(replica, replica_admin, SERVER_SYNC)
        assert server_sync["Version"] == "12.2.11.4", server_sync
        assert server_sync["Status"] == "Active", server_sync

    with subtest("Server Sync loads the seeded defaults"):
        config = server_sync_config(replica, replica_admin)
        assert config["LinkCacheSizeGb"] == 50, config
        assert config["MissingContentAction"] == "Delete", config
        assert config["DeleteMissingContentMode"] == "Enabled", config

    with subtest("R-SERVER-2, R-SERVER-6: dashboard changes survive restarts and activation"):
        write_admin_password(replica, "changed-pw")
        config = api(replica, "GET", f"/Plugins/{PEER_LOGIN}/Configuration", token=replica_admin)
        assert config["SourceUrl"] == "https://source", config
        config["SourceUrl"] = "https://source/"
        api(replica, "POST", f"/Plugins/{PEER_LOGIN}/Configuration", config, token=replica_admin, expect=204)
        restart_jellyfin(replica)
        replica.succeed("/run/current-system/bin/switch-to-configuration test")
        restart_jellyfin(replica)
        replica_admin = sign_in(replica, "replica-admin", "admin-pw")
        config = api(replica, "GET", f"/Plugins/{PEER_LOGIN}/Configuration", token=replica_admin)
        assert config["SourceUrl"] == "https://source/", config
        sign_in(replica, "alice", "alice-2")
        replica.wait_for_unit("jellyfin-initial-admin.service")
        assert admin_log(replica).count("system.xml marks the startup wizard complete") >= 2
        sign_in(replica, "replica-admin", "changed-pw", expect=401)

    with subtest("R-SERVER-5: a plugin disabled in the dashboard stays disabled"):
        api(replica, "POST", f"/Plugins/{SERVER_SYNC}/12.2.11.4/Disable", token=replica_admin, expect=204)
        restart_jellyfin(replica)
        replica_admin = sign_in(replica, "replica-admin", "admin-pw")
        server_sync = plugin(replica, replica_admin, SERVER_SYNC)
        assert server_sync["Status"] == "Disabled", server_sync
        assert server_sync["Version"] == "12.2.11.4", server_sync

    with subtest("R-PAIR-4: status names a stale administrator password file"):
        # The file still holds the password written for R-SERVER-6 after setup.
        out = status(replica, replica_admin, 1)
        assert "refused the sign-in as replica-admin" in out and ADMIN_PASSWORD_FILE in out, out
        write_admin_password(replica, "admin-pw")

    with subtest("R-PAIR-4: status reports a disabled Server Sync"):
        assert attention(replica, replica_admin, 3) == ["server-sync-inactive"]
        api(replica, "POST", f"/Plugins/{SERVER_SYNC}/12.2.11.4/Enable", token=replica_admin, expect=204)
        restart_jellyfin(replica)
        replica_admin = sign_in(replica, "replica-admin", "admin-pw")

    with subtest("R-PAIR-4: status reports a server without peers"):
        assert attention(source, source_admin, 3) == ["no-peers"]

    for machine in [source, replica]:
        for path, password in PASSWORDS.items():
            write_secret(machine, path, password)
    source.succeed(
        "mkdir -p '/srv/media/movies/Clip (2020)' '/srv/media/movies/Other (2021)'"
        " && cp ${media}/clip.mp4 '/srv/media/movies/Clip (2020)/Clip (2020).mp4'"
        " && cp ${media}/other.mp4 '/srv/media/movies/Other (2021)/Other (2021).mp4'"
    )

    def setup_command(machine, edit):
        """The wrapper's `sea-nettle setup --json` command, with `edit` applied to its spec."""
        wrapper = machine.succeed("cat $(readlink -f $(command -v sea-nettle))")
        found = re.search(r"--spec (\S+)", wrapper)
        assert found, wrapper
        spec_path = found.group(1)
        spec = json.loads(machine.succeed(f"cat {spec_path}"))
        edit(spec)
        machine.succeed(f"echo {shlex.quote(json.dumps(spec))} >/tmp/edited-spec.json")
        command = next(l for l in wrapper.splitlines() if l.startswith("exec "))
        return command.removeprefix("exec ").replace(spec_path, "/tmp/edited-spec.json").replace('"$@"', "setup --json")

    with subtest("R-PAIR-5: setup refuses an unsupported spec before changing anything"):
        command = setup_command(source, lambda spec: spec["source"]["syncAccount"].update(administrator=False))
        before = configuration(source, source_admin)
        out = setup(source, source_admin, 1, command=command)
        assert "nothing was changed" in out and "syncHistory needs source.syncAccount.administrator = true" in out, out
        assert configuration(source, source_admin) == before

    with subtest("R-PAIR-6, R-PAIR-8: setup on the source creates users, the library, and its sync account"):
        report = setup(source, source_admin, 3)
        # The replica has no sync account for the source yet.
        assert codes(report) == ["no-peers", "setup-peer-sign-in"], report
        assert report["changes"] == [
            "Created user carol",
            "Created library Movies at /srv/media/movies",
            "Created the administrator sync account replica-sync",
            "Allowed replica-sync to call this server's Server Sync",
        ], report
        options = library(source, source_admin, "Movies")["LibraryOptions"]
        assert not options["SaveLocalMetadata"] and not options["MetadataSavers"], options
        assert not options["SaveSubtitlesWithMedia"] and not options["SaveTrickplayWithMedia"], options
        sign_in(source, "carol", "carol-1")

    with subtest("R-PAIR-6: setup on the replica sets up its own side while the source is unreachable"):
        source.succeed("systemctl stop nginx.service")
        report = setup(replica, replica_admin, 3)
        assert "setup-peer-unreachable" in codes(report), report
        assert report["changes"] == [
            "Created library Movies at /var/lib/jellyfin/replica/movies",
            "Created the limited sync account source-sync",
            "Allowed source-sync to call this server's Server Sync",
        ], report
        source.succeed("systemctl start nginx.service")
        source_sync = replica_user("source-sync")
        assert not source_sync["Policy"]["IsAdministrator"] and not source_sync["Policy"]["EnableAllFolders"]

    with subtest("R-PAIR-4, R-PAIR-7: mappings stay disabled until the link check passes"):
        source_movies = library(source, source_admin, "Movies")["ItemId"]
        wait_for(lambda: len(movies(source, source_admin, source_movies)) == 2)
        report = setup(replica, replica_admin, 3)
        assert {"peer-not-listed", "setup-mappings-disabled"} <= set(codes(report)), report
        entry = replica_entry()
        assert entry["Mode"] == "Pull" and entry["AccessLevel"] == "Administrator", entry
        [mapping] = entry["LibraryMappings"]
        assert not mapping["IsEnabled"] and mapping["StorageMode"] == "Link", mapping
        assert [i["Name"] for i in mapping["FilteredItems"]] == ["Clip (2020)"], mapping
        assert sorted(m["LocalUserName"] for m in entry["UserMappings"]) == ["Alice", "bob", "source-admin"], entry
        assert not any(m["IsEnabled"] for m in entry["UserMappings"]), entry
        assert {"peer-not-listed", "unmapped-user"} <= set(attention(replica, replica_admin, 3))

    with subtest("R-PAIR-3, R-PAIR-6: setup ends the peer session it does not keep"):
        # The replica's account is limited, so a spec that asks for an administrator conflicts
        # only after Server Sync has signed in to it.
        command = setup_command(source, lambda spec: spec["replica"]["syncAccount"].update(administrator=True))
        before = configuration(source, source_admin)
        assert "conflict-sync-account" in codes(setup(source, source_admin, 3, command=command))
        assert configuration(source, source_admin) == before
        devices = api(replica, "GET", "/Devices", token=replica_admin)["Items"]
        assert not [d for d in devices if d.get("LastUserName") == "source-sync"], devices
        sessions = api(replica, "GET", "/Sessions", token=replica_admin)
        assert not [s for s in sessions if s.get("UserName") == "source-sync"], sessions

    with subtest("R-PAIR-6: setup on the source adds the replica and pairs"):
        report = setup(source, source_admin, 0)
        assert report["changes"] == ["Added the replica at https://replica as a Push peer, signed in as source-sync"], report
        entry = server_sync_config(source, source_admin)["Servers"][0]
        assert entry["Mode"] == "Push" and entry["AllowLinking"], entry

    with subtest("R-PAIR-7: setup enables the mappings once the link check passes, and defers new users"):
        report = setup(replica, replica_admin, 0)
        # Carol has not signed in to the replica yet; that needs no attention.
        assert codes(report) == [] and [w["code"] for w in report["waiting"]] == ["setup-user-deferred"], report
        config = server_sync_config(replica, replica_admin)
        assert config["EnableContentSync"] and config["EnableHistorySync"]
        entry = config["Servers"][0]
        assert entry["LibraryMappings"][0]["IsEnabled"]
        assert all(m["IsEnabled"] for m in entry["UserMappings"]), entry
        # Each direction logs one message on each side.
        for machine in [source, replica]:
            journal = machine.succeed("journalctl -b -u jellyfin.service")
            assert "it issued the secret this server presents to it" in journal
            assert "it now presents a secret this server issued" in journal

    with subtest("R-PAIR-6: a new user's mapping completes after their first replica sign-in"):
        sign_in(replica, "carol", "carol-1")
        report = setup(replica, replica_admin, 0)
        assert report["changes"] == ["Mapped user carol to the source (enabled)"], report

    with subtest("R-PAIR-7: each server lets only the spec's sync account call its Server Sync"):
        for machine, token, account in [(source, source_admin, "replica-sync"), (replica, replica_admin, "source-sync")]:
            grants = server_sync_config(machine, token)["PeerCallerGrants"]
            assert [(g["UserName"], g["Locations"]) for g in grants] == [(account, [])], grants

    with subtest("R-PAIR-6: a rerun changes nothing"):
        for machine, token in [(source, source_admin), (replica, replica_admin)]:
            before = configuration(machine, token)
            assert setup(machine, token, 0)["changes"] == []
            assert configuration(machine, token) == before

    with subtest("the replica links only the whitelisted movie and streams it from the source"):
        links = "find /var/lib/jellyfin/replica/movies -name '*.strm'"
        for _ in range(30):
            api(replica, "POST", "/Sync/TriggerRefresh", token=replica_admin)
            time.sleep(5)
            api(replica, "POST", "/Sync/TriggerSync", token=replica_admin)
            time.sleep(5)
            if replica.succeed(links).strip():
                break
        assert replica.succeed(links).strip().splitlines() == ["/var/lib/jellyfin/replica/movies/Clip (2020)/Clip (2020).strm"], replica.succeed("find /var/lib/jellyfin/replica")
        replica_movies = library(replica, replica_admin, "Movies")["ItemId"]
        api(replica, "POST", "/Library/Refresh", token=replica_admin, expect=204)
        wait_for(lambda: movies(replica, replica_admin, replica_movies))
        [clip] = movies(replica, replica_admin, replica_movies)
        alice_token = sign_in(replica, "alice", "alice-2")
        # A player asks for playback info first; then the replica asks the source whether Alice may stream.
        api(replica, "POST", f"/Items/{clip['Id']}/PlaybackInfo?userId={replica_user('Alice')['Id']}", {}, token=alice_token)
        auth = f'Authorization: MediaBrowser Client="VM Test", Device="vm", DeviceId="vm-alice", Version="1", Token="{alice_token}"'
        replica.succeed(f"curl -sf -o /tmp/clip.mp4 -H {shlex.quote(auth)} 'http://127.0.0.1:8096/Videos/{clip['Id']}/stream?static=true'")
        expected = hashlib.sha256(open("${media}/clip.mp4", "rb").read()).hexdigest()
        assert replica.succeed("sha256sum /tmp/clip.mp4").split()[0] == expected

    with subtest("R-PAIR-6: setup keeps dashboard edits and reports conflicts without writing"):
        set_entry(source, source_admin, LinkMaxStreams=2)
        set_mapping(replica, replica_admin, ExcludeFromLinkCache=True)
        api(source, "POST", f"/Users/{source_user_id('carol')}/Password", {"NewPw": "carol-2"}, token=source_admin, expect=204)
        for machine, token in [(source, source_admin), (replica, replica_admin)]:
            assert setup(machine, token, 0)["changes"] == []
        assert server_sync_config(source, source_admin)["Servers"][0]["LinkMaxStreams"] == 2
        assert replica_entry()["LibraryMappings"][0]["ExcludeFromLinkCache"]
        # Setup never resets an existing user's password.
        sign_in(source, "carol", "carol-2")
        movies_library = library(source, source_admin, "Movies")
        options = dict(movies_library["LibraryOptions"], SaveLocalMetadata=True)
        set_options = lambda: api(source, "POST", "/Library/VirtualFolders/LibraryOptions", {"Id": movies_library["ItemId"], "LibraryOptions": options}, token=source_admin, expect=204)
        set_options()
        assert codes(setup(source, source_admin, 3)) == ["library-writes-beside-media"]
        options["SaveLocalMetadata"] = False
        set_options()
        set_mapping(replica, replica_admin, StorageMode="Copy")
        before = configuration(replica, replica_admin)
        assert codes(setup(replica, replica_admin, 3)) == ["conflict-mapping"]
        assert configuration(replica, replica_admin) == before
        set_mapping(replica, replica_admin, StorageMode="Link")
        # A changed URL would drop the stored key, so the direction stands in for an entry conflict.
        set_entry(replica, replica_admin, Mode="Push")
        assert "conflict-entry-mode" in codes(setup(replica, replica_admin, 3))
        set_entry(replica, replica_admin, Mode="Pull")
        assert attention(replica, replica_admin, 0) == []

    with subtest("R-PAIR-4: status reports an unpaired peer"):
        set_entry(source, source_admin, IsEnabled=False)
        assert attention(replica, replica_admin, 3) == ["peer-unpaired"]
        set_entry(source, source_admin, IsEnabled=True)
        assert attention(replica, replica_admin, 0) == []

    with subtest("R-PAIR-4: status reports a missing or mismatched server ID"):
        set_entry(replica, replica_admin, ServerId="")
        assert "entry-no-server-id" in attention(replica, replica_admin, 3)
        set_entry(replica, replica_admin, ServerId="0123456789abcdef0123456789abcdef")
        assert "entry-server-id-mismatch" in attention(replica, replica_admin, 3)
        set_entry(replica, replica_admin, ServerId=api(source, "GET", "/System/Info/Public")["Id"])
        assert attention(replica, replica_admin, 0) == []

    with subtest("R-PAIR-4: status reports an unreachable peer"):
        source.succeed("systemctl stop nginx.service")
        assert attention(replica, replica_admin, 3) == ["peer-unreachable"]
        source.succeed("systemctl start nginx.service")
        assert attention(replica, replica_admin, 0) == []

    passwords = ["admin-pw", "changed-pw", "carol-2"] + list(PASSWORDS.values())
    grep_passwords = " ".join(f"-e {shlex.quote(p)}" for p in passwords)

    with subtest("R-PAIR-2: the commands never reveal credentials"):
        stored_keys = [s["ApiKey"] for m, t in [(source, source_admin), (replica, replica_admin)] for s in server_sync_config(m, t)["Servers"]]
        assert all(stored_keys), stored_keys
        for out in outputs:
            for secret in passwords + stored_keys:
                assert secret not in out, f"sea-nettle printed a secret: {out}"
        for machine in [source, replica]:
            wrapper = machine.succeed("readlink -f $(command -v sea-nettle)").strip()
            assert f"--password-file {ADMIN_PASSWORD_FILE}" in machine.succeed(f"cat {wrapper}")
            machine.succeed(f"nix-store -qR {wrapper} >/tmp/closure")
            machine.fail(f"xargs grep -rlF {grep_passwords} </tmp/closure")

    with subtest("R-SERVER-6, R-PAIR-2: passwords never reach the journal"):
        for machine in [source, replica]:
            machine.fail(f"journalctl -b --no-pager | grep -F {grep_passwords}")
  '';
}
