{
  description = "nod-exec: TCP command server for Nix-on-Droid";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nod-exec = pkgs.callPackage ./package.nix {};
      in {
        packages = {
          default = nod-exec.server;
          server = nod-exec.server;
          client = nod-exec.client;
          nc = nod-exec.nc;
          android = nod-exec.android;
        };

        apps = {
          default = {
            type = "app";
            program = "${nod-exec.server}/bin/nod-exec-server";
          };
          server = {
            type = "app";
            program = "${nod-exec.server}/bin/nod-exec-server";
          };
          client = {
            type = "app";
            program = "${nod-exec.client}/bin/nod-exec";
          };
        };

        overlays.default = final: prev: {
          nod-exec = prev.callPackage ./package.nix {};
        };
      }
    );
}
