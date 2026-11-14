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

  server = {
    # Jellyfin refuses to start with less than 2 GiB free in its data directory.
    virtualisation.diskSize = 4096;
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.util-linux ];
    # The test writes the password at runtime, so it never reaches the Nix store (R-SERVER-6).
    sea-nettle.jellyfin.initialAdmin.passwordFile = "/run/jellyfin-admin-password";
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
    sea-nettle.jellyfin = {
      initialAdmin.name = "replica-admin";
      replica.sourceUrl = "https://source";
    };
    # The test re-runs activation (R-SERVER-2).
    system.switch.enable = true;
  };

  testScript = ''
    import itertools
    import json
    import shlex
    import uuid

    PEER_LOGIN = "74c2e693-6ab7-40fa-858d-c752d48cb45c"
    SERVER_SYNC = "ebd650b5-6f4c-4ccb-b10d-23dffb3a7286"
    PEER_PROVIDER = "Jellyfin.Plugin.PeerLogin.PeerAuthenticationProvider"
    ADMIN_PASSWORD_FILE = "/run/jellyfin-admin-password"
    SYNC_PASSWORD = "sync-pw"


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


    def write_admin_password(machine, password):
        machine.succeed(f"(umask 077; printf '%s\\n' {shlex.quote(password)} >{ADMIN_PASSWORD_FILE})")


    def wizard_completed(machine):
        return api(machine, "GET", "/System/Info/Public")["StartupWizardCompleted"]


    def unit_time(machine, unit, prop):
        return int(machine.succeed(f"systemctl show -P {prop} {unit}"))


    def admin_log(machine):
        return machine.succeed("journalctl -b -o cat -u jellyfin-initial-admin.service")


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


    def allow_caller(machine, token, user):
        grant = {"UserId": user["Id"], "UserName": user["Name"], "Locations": []}
        edit_server_sync_config(machine, token, lambda c: c["PeerCallerGrants"].append(grant))


    # Tokens and stored keys that `sea-nettle status` must never print (R-PAIR-2).
    sync_tokens = []


    def add_peer(machine, token, name, url, username, mode):
        """Adds a peer entry as the dashboard's Sign In does."""
        signed = api(machine, "POST", "/Sync/Authenticate", {"ServerUrl": url, "Username": username, "Password": SYNC_PASSWORD}, token=token)
        assert signed["Success"], signed
        sync_tokens.append(signed["AccessToken"])
        entry = {
            "Key": uuid.uuid4().hex,
            "Name": name,
            "Url": url,
            "ApiKey": signed["AccessToken"],
            "AuthenticatedUser": signed["Username"],
            "AuthenticatedUserId": signed["UserId"],
            "ServerName": signed["ServerName"],
            "ServerId": signed["ServerId"],
            "AccessLevel": "Administrator" if signed["IsAdministrator"] else "User",
            "Mode": mode,
        }
        edit_server_sync_config(machine, token, lambda c: c["Servers"].append(entry))
        return entry


    def configuration(machine, token):
        """What `sea-nettle status` must leave unchanged (R-PAIR-1)."""
        active = plugin(machine, token, SERVER_SYNC)["Status"] == "Active"
        # Jellyfin's sign-in bookkeeping: every sign-in, including the command's own, updates
        # these, and a failed one counts toward lockout.
        users = []
        for user in api(machine, "GET", "/Users", token=token):
            user = {k: v for k, v in user.items() if k not in ("LastLoginDate", "LastActivityDate")}
            user["Policy"] = {k: v for k, v in user["Policy"].items() if k != "InvalidLoginAttemptCount"}
            users.append(user)
        return (
            server_sync_config(machine, token) if active else None,
            users,
            api(machine, "GET", "/Library/VirtualFolders", token=token),
        )


    status_outputs = []


    def status(machine, token, expect, text=False):
        """Runs `sea-nettle status` and returns its output; checks R-PAIR-1 and R-PAIR-3 around every run."""
        before = configuration(machine, token)
        flags = "" if text else " --json"
        code, out = machine.execute(f"sea-nettle status{flags} 2>/tmp/status-stderr")
        err = machine.succeed("cat /tmp/status-stderr")
        status_outputs.append(out + err)
        assert code == expect, f"{machine.name}: status exited {code}, expected {expect}: {out}{err}"
        assert configuration(machine, token) == before, f"{machine.name}: status changed the configuration"
        devices = api(machine, "GET", "/Devices", token=token)["Items"]
        assert not [d for d in devices if d.get("AppName") == "sea-nettle"], devices
        sessions = api(machine, "GET", "/Sessions", token=token)
        assert not [s for s in sessions if s.get("Client") == "sea-nettle"], sessions
        if text or code not in (0, 3):
            # A failed run prints its error to stderr.
            return out + err
        return json.loads(out)


    def attention(machine, token, expect):
        """The attention codes of a status report."""
        return sorted(a["code"] for a in status(machine, token, expect)["attention"])


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

    # Each server's key on the other belongs to a dedicated account. The replica's key on the
    # source is an administrator's, so user mappings sync; the source's key is a standard user's.
    replica_sync = api(source, "POST", "/Users/New", {"Name": "replica-sync", "Password": SYNC_PASSWORD}, token=source_admin)
    replica_sync["Policy"]["IsAdministrator"] = True
    api(source, "POST", f"/Users/{replica_sync['Id']}/Policy", replica_sync["Policy"], token=source_admin, expect=204)
    source_sync = api(replica, "POST", "/Users/New", {"Name": "source-sync", "Password": SYNC_PASSWORD}, token=replica_admin)

    with subtest("R-PAIR-4: status reports a peer that does not list this server"):
        allow_caller(source, source_admin, replica_sync)
        source_entry = add_peer(replica, replica_admin, "source", "https://source", "replica-sync", "Pull")
        assert "peer-not-listed" in attention(replica, replica_admin, 3)

    with subtest("R-PAIR-4: status pairs both directions and reports unmapped Peer Login users"):
        allow_caller(replica, replica_admin, source_sync)
        add_peer(source, source_admin, "replica", "https://replica", "source-sync", "Push")
        assert attention(source, source_admin, 0) == []
        assert attention(replica, replica_admin, 3) == ["unmapped-user"] * 3
        # Each direction logs one message on each side.
        for machine in [source, replica]:
            journal = machine.succeed("journalctl -b -u jellyfin.service")
            assert "it issued the secret this server presents to it" in journal
            assert "it now presents a secret this server issued" in journal

    with subtest("R-PAIR-4: status passes once Peer Login users are mapped"):
        api(source, "POST", "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=/srv/media", {}, token=source_admin, expect=204)
        api(replica, "POST", "/Library/VirtualFolders?name=Replica%20Movies&collectionType=movies&paths=/var/lib/jellyfin/replica", {}, token=replica_admin, expect=204)
        source_library = api(source, "GET", "/Library/VirtualFolders", token=source_admin)[0]
        replica_library = api(replica, "GET", "/Library/VirtualFolders", token=replica_admin)[0]
        source_users = {u["Name"]: u for u in api(source, "GET", "/Users", token=source_admin)}

        def map_users_and_library(config):
            entry = config["Servers"][0]
            entry["LibraryMappings"].append({
                "SourceLibraryId": source_library["ItemId"],
                "SourceLibraryName": source_library["Name"],
                "SourceRootPath": "/srv/media",
                "LocalLibraryId": replica_library["ItemId"],
                "LocalLibraryName": replica_library["Name"],
                "LocalRootPath": "/var/lib/jellyfin/replica",
                "StorageMode": "Link",
                "IsEnabled": False,
            })
            for user in api(replica, "GET", "/Users", token=replica_admin):
                if user["Policy"]["AuthenticationProviderId"] == PEER_PROVIDER:
                    entry["UserMappings"].append({
                        "SourceUserId": source_users[user["Name"]]["Id"],
                        "SourceUserName": user["Name"],
                        "LocalUserId": user["Id"],
                        "LocalUserName": user["Name"],
                    })

        edit_server_sync_config(replica, replica_admin, map_users_and_library)
        assert attention(replica, replica_admin, 0) == []
        assert "Nothing needs attention." in status(replica, replica_admin, 0, text=True)

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
        set_entry(replica, replica_admin, ServerId=source_entry["ServerId"])
        assert attention(replica, replica_admin, 0) == []

    with subtest("R-PAIR-4: status reports an unreachable peer"):
        source.succeed("systemctl stop nginx.service")
        assert attention(replica, replica_admin, 3) == ["peer-unreachable"]
        source.succeed("systemctl start nginx.service")
        assert attention(replica, replica_admin, 0) == []

    with subtest("R-PAIR-2: status never reveals credentials"):
        stored_keys = [s["ApiKey"] for m, t in [(source, source_admin), (replica, replica_admin)] for s in server_sync_config(m, t)["Servers"]]
        assert all(stored_keys), stored_keys
        secrets = ["admin-pw", "changed-pw", SYNC_PASSWORD] + sync_tokens + stored_keys
        for out in status_outputs:
            for secret in secrets:
                assert secret not in out, f"status printed a secret: {out}"
        for machine in [source, replica]:
            wrapper = machine.succeed("readlink -f $(command -v sea-nettle)").strip()
            assert f"--password-file {ADMIN_PASSWORD_FILE}" in machine.succeed(f"cat {wrapper}")
            machine.succeed(f"nix-store -qR {wrapper} >/tmp/closure")
            machine.fail("xargs grep -rlF -e admin-pw -e changed-pw </tmp/closure")

    with subtest("R-SERVER-6: administrator passwords never reach the journal"):
        for machine in [source, replica]:
            machine.fail("journalctl -b --no-pager | grep -F -e admin-pw -e changed-pw")
  '';
}
