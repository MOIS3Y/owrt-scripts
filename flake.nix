{
  description = "Development environment for OpenWrt scripts and documentation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Documentation
            mdbook
            mdbook-toc

            # Script Development & Testing
            busybox
            shellcheck
            shfmt
            bats

            # Tools
            git
          ];

          shellHook = ''
            echo "--- OpenWrt Scripts Development Environment ---"
            echo "Available tools: mdbook, shellcheck, shfmt, bats"
          '';
        };
      }
    );
}
