{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  name = "sea-nettle";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [ ];
  buildInputs = [ ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      'echo "Hello from sea-nettle"' \
      >"$out/bin/sea-nettle"
    chmod +x "$out/bin/sea-nettle"

    runHook postInstall
  '';

  meta.mainProgram = "sea-nettle";
}
