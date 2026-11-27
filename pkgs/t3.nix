# T3 Code server (MIT, github.com/pingdotgg/t3code), official release tarball,
# pinned by version and sha256 (the hash equals the release asset digest that
# GitHub publishes). The binary is used unmodified: it is a Node single
# executable whose payload must not be rewritten by patchelf, so it runs
# through nix-ld inside the bay (programs.nix-ld in modules/guest.nix).
#
# Update: bump version, then
#   nix store prefetch-file --hash-type sha256 <url>
# and compare with `gh release view v<version> -R pingdotgg/t3code --json assets`.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "t3code";
  version = "0.1.11";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${finalAttrs.version}/t3-${finalAttrs.version}-linux-x64.tar.gz";
    hash = "sha256-K2kcB/W8ta3qSoY9UySq59shvW2CKAzsd4eDbcqgE+E=";
  };

  dontConfigure = true;
  dontBuild = true;
  # Keep the release bytes as published: no strip, no patchelf, no shebang rewrites.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/t3 $out/bin
    cp -a . $out/libexec/t3/
    # A symlink (not a wrapper) so /proc/self/exe and $ORIGIN/lib resolve to the release dir.
    ln -s $out/libexec/t3/t3 $out/bin/t3
    runHook postInstall
  '';

  meta = {
    description = "T3 Code server (official release binary)";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "t3";
  };
})
