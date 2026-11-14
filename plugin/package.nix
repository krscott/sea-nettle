{
  lib,
  buildDotnetModule,
  dotnetCorePackages,
  writeText,
}:

let
  version = "0.1.0";
  # Matches Plugin.Id and Plugin.Name in the C# project.
  meta = writeText "meta.json" (
    builtins.toJSON {
      guid = "74c2e693-6ab7-40fa-858d-c752d48cb45c";
      name = "Peer Login";
      version = "${version}.0";
      targetAbi = "12.4.0.0";
      timestamp = "1970-01-01T00:00:00Z";
      overview = "Sign in with the credentials of a source Jellyfin server.";
      description = "Forwards sign-ins to a source Jellyfin server and caches the last accepted password for source outages.";
      category = "Authentication";
      owner = "krscott";
      changelog = "";
      status = "Active";
      autoUpdate = false;
      assemblies = [ "Jellyfin.Plugin.PeerLogin.dll" ];
    }
  );
in
buildDotnetModule {
  pname = "jellyfin-plugin-peer-login";
  inherit version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Jellyfin.Plugin.PeerLogin
      ./Jellyfin.Plugin.PeerLogin.Tests
    ];
  };

  projectFile = "Jellyfin.Plugin.PeerLogin/Jellyfin.Plugin.PeerLogin.csproj";
  testProjectFile = "Jellyfin.Plugin.PeerLogin.Tests/Jellyfin.Plugin.PeerLogin.Tests.csproj";
  doCheck = true;
  nugetDeps = ./deps.json;
  dotnet-sdk = dotnetCorePackages.sdk_10_0;
  dotnetFlags = [ "-p:Version=${version}" ];
  executables = [ ];

  # The output is a Jellyfin plugin directory: the assembly and its manifest.
  postInstall = ''
    mv "$out/lib/$pname/Jellyfin.Plugin.PeerLogin.dll" "$out/"
    rm -r "$out/lib"
    install -m 0444 ${meta} "$out/meta.json"
  '';

  meta = {
    description = "Jellyfin plugin that signs replica users in with source server credentials";
    platforms = lib.platforms.linux;
  };
}
