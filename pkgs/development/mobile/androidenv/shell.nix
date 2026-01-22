{ pkgs ? import ../../../.. {} }:

pkgs.mkShell {
  packages = [
    (pkgs.python3.withPackages (ps: with ps; [
      beautifulsoup4
      lxml
      pydantic
      requests
      returns
    ]))
  ];
}