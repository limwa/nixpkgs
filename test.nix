let
  pkgs = import ./. {
    localSystem = "x86_64-linux";
    crossSystem = "aarch64-linux";
    config = {
      problems.handlers = {
        SPIRV-LLVM-Translator.broken = "warn"; # or "ignore"
      };
    };
  };

  inherit (pkgs) lib;

  getPairForVersion = pkgSet: version: { snd, ... }: let fst = snd; in
    if fst.name != snd.name then
      throw "Package names differ: ${fst.name} != ${snd.name}"
    else {
      inherit pkgSet version;
      pkg = fst.name;

      before = fst.outPath;
      after = snd.outPath;
    };

  warnIfDifferent = pair: if pair.before != pair.after then (builtins.trace "Warning (${pair.pkgSet}/${pair.version}/${pair.pkg}): ${pair.before} != ${pair.after}" "") else "";

  pkgSets = [
    "pkgs"
    "pkgsBuildBuild"
    "pkgsBuildHost"
    "pkgsBuildTarget"
    "pkgsHostHost"
    "pkgsHostTarget"
    "pkgsTargetTarget"
  ];

  versions = [
    "18"
    "19"
    "20"
    "21"
    "22"
  ];

  yieldResultsFor = pkgSet: version: let
      beforePkgs = pkgs.${pkgSet}."llvmPackages_${version}" or {};
      afterPkgs = pkgs.${pkgSet}."dart-llvm-test"."${version}" or {};

      yieldBeforePkgs = pkgs.lib.collect (x: x ? outPath) beforePkgs;
      yieldedAfterPkgs = pkgs.lib.collect (x: x ? outPath) afterPkgs;
    in
      pkgs.lib.concatStringsSep "" (
        pkgs.lib.map warnIfDifferent (
          pkgs.lib.map (getPairForVersion pkgSet version) (
            pkgs.lib.zipLists yieldBeforePkgs yieldedAfterPkgs
          )
        )
      );
in
pkgs.lib.crossLists yieldResultsFor [pkgSets versions]
