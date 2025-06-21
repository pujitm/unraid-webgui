# flake.nix
# The purpose of this flake is to "cross-compile" a phoenix project to x86_64 from a macos host
{
  description = "Phoenix cross-compiled with Nix";

  ##########################################################################
  ## 1. Inputs
  ##########################################################################
  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url   = "github:numtide/flake-utils";
  };

  ##########################################################################
  ## 2. Outputs
  ##########################################################################
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [
      "aarch64-darwin"      # dev machine (Apple Silicon)
      "x86_64-linux"        # target container
    ] (system:
      let
        #############
        # 2.1 pkgs  #
        #############
        overlay-openssl = final: prev: {
          openssl = if prev.openssl ? overrideAttrs then
            prev.openssl.overrideAttrs (_: rec {
              pname   = "openssl";
              version = "3.5.0";
              src     = prev.fetchurl {
                url    = "https://www.openssl.org/source/openssl-${version}.tar.gz";
                sha256 = "sha256-CHANGE-ME";
              };
            })
          else
            prev.openssl;
        };

        overlays = [ overlay-openssl ];

        # Native packages for the current system (used for devShell, tools…)
        pkgs = import nixpkgs { inherit system overlays; };

        # Cross-compiled packages that target x86_64-linux when we are on
        # Apple-Silicon macOS.  On x86_64-linux hosts we just re-use `pkgs`.
        pkgsTarget = if system == "aarch64-darwin" then
          import nixpkgs {
            inherit system;
            crossSystem = { config = "x86_64-linux"; };
          }
        else pkgs;

        #############
        # 2.2 build #
        #############
        pname      = "unraid_view";
        version    = "0.1.0";
        src        = ./.;
        
        erl        = pkgsTarget.beam.interpreters.erlang_27;
        hostErl    = pkgs.beam.interpreters.erlang_27;
        # Select the Elixir version that matches our Erlang interpreter.
        # beam.packagesWith takes the interpreter as its argument and returns
        # an attribute set containing all BEAM packages built with that
        # interpreter. We then pick the Elixir package we need.
        elixir     = (pkgsTarget.beam.packagesWith erl).elixir_1_18;
        hostElixir = (pkgs.beam.packagesWith hostErl).elixir_1_18;

        # A self-contained release (no Erlang installed on the host)
        phx-release = pkgsTarget.beam.packages.buildMix {
          inherit pname version src;
          # buildMix handles Mix dependencies automatically
        };

      in
      {
        ###################
        # 2.3 dev shell   #
        ###################
        devShells.default = pkgs.mkShell {
          buildInputs = [
            hostErl hostElixir pkgs.git pkgs.openssl
          ];
          # Let Phoenix find OpenSSL headers when compiling cowboy's deps
          PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
        };

        ###################
        # 2.4 packages    #
        ###################
        packages = {
          phx-release = phx-release;

          # OCI / Docker image ~30 MB
          container = pkgsTarget.dockerTools.buildLayeredImage {
            name   = "unraid_view";
            tag    = "latest";
            contents = [
              pkgsTarget.openssl
              phx-release
              pkgsTarget.busybox # for sh
            ];
            config = {
              Cmd = [ "${phx-release}/bin/unraid_view" "start" ];
              WorkingDir = "/var/lib/unraid_view";
              Env = [ "LANG=C.UTF-8" ];
            };
          };
          default = phx-release;   # what `nix build .` gives you
        };
      });
}
