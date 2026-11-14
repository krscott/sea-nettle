# A source and a replica Jellyfin. The source serves HTTPS through nginx with a test certificate.
{ pkgs, ... }:

let
  certs = pkgs.runCommand "source-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir "$out"
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj /CN=source \
      -addext subjectAltName=DNS:source \
      -keyout "$out/source.key" -out "$out/source.crt"
  '';

  server = {
    # Jellyfin refuses to start with less than 2 GiB free in its data directory.
    virtualisation.diskSize = 4096;
    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.util-linux ];
    # The test writes the password at runtime, so it never reaches the Nix store (R-SERVER-6).
    sea-nettle.jellyfin.initialAdmin.passwordFile = "/run/jellyfin-admin-password";
  };
in
{
  name = "replica-login";

  nodes.source =
    { lib, ... }:
    {
      imports = [
        server
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
      # dependencies. nginx below stands in for the proxy.
      services.tailscale.enable = true;
      systemd.services.jellyfin-serve.serviceConfig = {
        ExecStart = lib.mkForce "${pkgs.coreutils}/bin/true";
        ExecStop = lib.mkForce "${pkgs.coreutils}/bin/true";
      };

      services.nginx = {
        enable = true;
        virtualHosts.source = {
          onlySSL = true;
          sslCertificate = "${certs}/source.crt";
          sslCertificateKey = "${certs}/source.key";
          locations."/".proxyPass = "http://127.0.0.1:8096";
        };
      };
      networking.firewall.allowedTCPPorts = [ 443 ];
    };

  nodes.replica = {
    imports = [
      server
      ../modules/replica.nix
    ];
    sea-nettle.jellyfin = {
      initialAdmin.name = "replica-admin";
      replica.sourceUrl = "https://source";
    };
    security.pki.certificateFiles = [ "${certs}/source.crt" ];
    # The test re-runs activation (R-SERVER-2).
    system.switch.enable = true;
  };

  testScript = ''
    import itertools
    import json
    import shlex

    PEER_LOGIN = "74c2e693-6ab7-40fa-858d-c752d48cb45c"
    SERVER_SYNC = "ebd650b5-6f4c-4ccb-b10d-23dffb3a7286"
    PEER_PROVIDER = "Jellyfin.Plugin.PeerLogin.PeerAuthenticationProvider"
    ADMIN_PASSWORD_FILE = "/run/jellyfin-admin-password"


    # Jellyfin revokes a user's earlier token when they sign in again from the same device.
    device_ids = itertools.count()


    def api(machine, method, path, body=None, token=None, expect=200, device="vm-test", base="http://127.0.0.1:8096"):
        auth = f'MediaBrowser Client="VM Test", Device="vm", DeviceId="{device}", Version="1"'
        if token:
            auth += f', Token="{token}"'
        cmd = (
            f"curl -sS -o /tmp/body -w '%{{http_code}}' -X {method}"
            f" {base}{path} -H {shlex.quote('Authorization: ' + auth)}"
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
        restart_jellyfin(source)
        assert wizard_completed(source)
        source.succeed("systemctl start jellyfin-serve.service")
        assert "already complete" in admin_log(source)
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
        assert admin_log(replica).count("already complete") >= 2
        sign_in(replica, "replica-admin", "changed-pw", expect=401)

    with subtest("R-SERVER-5: a plugin disabled in the dashboard stays disabled"):
        api(replica, "POST", f"/Plugins/{SERVER_SYNC}/12.2.11.4/Disable", token=replica_admin, expect=204)
        restart_jellyfin(replica)
        replica_admin = sign_in(replica, "replica-admin", "admin-pw")
        server_sync = plugin(replica, replica_admin, SERVER_SYNC)
        assert server_sync["Status"] == "Disabled", server_sync
        assert server_sync["Version"] == "12.2.11.4", server_sync

    with subtest("R-SERVER-6: administrator passwords never reach the journal"):
        for machine in [source, replica]:
            machine.fail("journalctl -b --no-pager | grep -F -e admin-pw -e changed-pw")
  '';
}
