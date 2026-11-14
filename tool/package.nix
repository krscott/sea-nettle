{
  lib,
  python3Packages,
  pyright,
}:

python3Packages.buildPythonApplication {
  pname = "sea-nettle";
  version = "0.1.0";
  pyproject = true;
  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  nativeCheckInputs = [
    python3Packages.mypy
    python3Packages.pytestCheckHook
    pyright
  ];

  preCheck = ''
    mypy sea_nettle tests
    pyright sea_nettle tests
  '';

  # Ignore the caller's Python imports; Nix fixup still adds the packaged site.
  postInstall = ''
    sed -i '1s/$/ -I/' "$out/bin/sea-nettle"
  '';

  meta = {
    description = "Checks a sea-nettle server's Server Sync setup";
    mainProgram = "sea-nettle";
  };
}
