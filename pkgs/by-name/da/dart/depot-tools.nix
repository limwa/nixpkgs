{
  stdenv,
  fetchgit,
}:

stdenv.mkDerivation {
  pname = "depot-tools";
  version = "";
  
  src = fetchgit {
    url = "https://chromium.googlesource.com/chromium/tools/depot_tools.git";
    rev = "364ccfdd5f1346dc973b66ab5f088a4ec88ca8c6";
    hash = "sha256-fggeoJuyONPhBKlwQXs/oak1GuqypImWLwLMyHRMFJM=";
  };
  
  installPhase = ''
    mkdir "$out"
    cp -aR . "$out"
  '';
  
}

