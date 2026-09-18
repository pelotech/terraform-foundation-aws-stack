{
  description = "terraform-foundation-aws-stack dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, ... }:
        {
          devShells.default = pkgs.mkShell {
            # tenv's terraform proxy installs the version .terraform-version resolves to
            # (min-required: the required_version floor in versions.tf, same as CI).
            env.TENV_AUTO_INSTALL = "true";
            packages = with pkgs; [
              # terraform
              tenv

              # pre-commit (prek runs .pre-commit-config.yaml)
              prek
              tflint
              hcledit
              terraform-docs
              trivy
              yamllint
              actionlint
              zizmor
            ];
          };
        };
    };
}
