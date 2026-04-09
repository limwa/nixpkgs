{
  callPackage,
}:

let 
  makeScopeWithSplicing'' = 
    args:
    let
      tryCallPackage = pkgSet: fnOrPath: args:
        if pkgSet ? callPackage then
          pkgSet.callPackage fnOrPath args
        else
          {};
          
      scopeWithSplicingFn = pkgSet: tryCallPackage pkgSet (
        {
          makeScopeWithSplicing',
          pkgsBuildBuild,
          pkgsBuildHost,
          pkgsBuildTarget,
          pkgsHostHost,
          pkgsHostTarget,
          pkgsTargetTarget,
        }:
        makeScopeWithSplicing' (args // {
          otherSplices = {
            selfBuildBuild = scopeWithSplicingFn pkgsBuildBuild;
            selfBuildHost = scopeWithSplicingFn pkgsBuildHost;
            selfBuildTarget = scopeWithSplicingFn pkgsBuildTarget;
            selfHostHost = scopeWithSplicingFn pkgsHostHost;
            selfHostTarget = scopeWithSplicingFn pkgsHostTarget;
            selfTargetTarget = scopeWithSplicingFn pkgsTargetTarget;
          };
        })
      ) {};
      
    in
    scopeWithSplicingFn { inherit callPackage; };
  
  scope = makeScopeWithSplicing'' {
    extra = _spliced0: {
      # constants is not a package so doesn't need to be spliced
      constants = import ./constants.nix;
    };
    
    f = (self: {
      cipd = self.callPackage ./cipd.nix {};
      depot-tools = self.callPackage ./depot-tools.nix {};
      
      src = self.callPackage ./source {};
      
      dart = self.callPackage ./dart.nix { scope = self; };
    });
  };
in scope.dart