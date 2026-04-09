{
  stdenv,
  constants,
  fetchurl,
  writeShellScriptBin,
}:

let
  inherit (constants.forStdenv stdenv) buildConstants hostConstants;
  
  cipdBin = fetchurl {
    url = "https://chrome-infra-packages.appspot.com/client?platform=${hostConstants.alt-os}-${hostConstants.arch}&version=git_revision:927335d3d594ba6b46a8c3f2d64fade13c22075b";
    executable = true;
    hash =
      {
        "linux-amd64" = "sha256-CP3AbEJm9vbyYfEnF9eD/vZwWK8Ps7kqQjZPY+HTuSQ=";
        "linux-arm64" = "sha256-C97vamQ/+/0aaro+idwogtamQUfeVAopHQ1mdID2Utc=";
        "mac-amd64" = "sha256-oyxJAG2Xg7m6w/IYrFgEPw0qLCTjL3/XB/3npod2Xsg=";
        "mac-arm64" = "sha256-a0bD+qSn34Edn63o7rmQ4v4IVWnETIgWbxDZ1igNbP4=";
      }
      ."${hostConstants.alt-os}-${hostConstants.arch}";
  };
in

stdenv.mkDerivation {
  pname = "cipd";
  version = ""
}




writeShellScriptBin "cipd" ''
  if [[ "$1" == "ensure" ]]; then
    for arg in "$@"; do
      if [[ "$prev" == "-ensure-file" ]]; then
        sed --in-place \
          --expression='s/''${platform}/${hostConstants.platform}/g' \
          --expression='s|gn/gn/${hostConstants.platform}|gn/gn/${buildConstants.platform}|g' \
          --expression='\|src/flutter/third_party/java/openjdk|,+2 d' \
          "$arg"
        break
      fi
      prev="$arg"
    done
  fi

  exec ${cipdBin} "$@"
''
