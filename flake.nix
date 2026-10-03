# The dev shell: Elixir, and the moq-relay binary the integration tests run.
#
#   nix develop
#   mix deps.get
#   mix test --include integration
{
  description = "ex_moq_relay: runs moq-relay as a supervised OS process";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Upstream's prebuilt binary, the same version as CI's, see
      # .github/workflows/ci.yml.
      moqRelayVersion = "0.15.8";
      moqRelayReleases = {
        aarch64-darwin = {
          target = "aarch64-apple-darwin";
          hash = "sha256-AsI2XZ/DeSCvk4NMvBPrTYMv2qZygBdEktQ4nEg31YU=";
        };
        aarch64-linux = {
          target = "aarch64-unknown-linux-gnu";
          hash = "sha256-AW0IRQ78sntTCSvMNCzdL91zeaM5ccMi566G0SOwYb4=";
        };
        x86_64-linux = {
          target = "x86_64-unknown-linux-gnu";
          hash = "sha256-L738+lzdDh2s2JV1ZGSLSHn6XbCQ3AIhuoAmP7cS2Hk=";
        };
      };

      moqRelay =
        pkgs:
        let
          release = moqRelayReleases.${pkgs.stdenv.hostPlatform.system};
        in
        pkgs.stdenv.mkDerivation {
          pname = "moq-relay";
          version = moqRelayVersion;
          src = pkgs.fetchurl {
            url = "https://github.com/moq-dev/moq/releases/download/moq-relay-v${moqRelayVersion}/moq-relay-v${moqRelayVersion}-${release.target}.tar.gz";
            inherit (release) hash;
          };
          nativeBuildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.autoPatchelfHook
          ];
          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.stdenv.cc.cc.lib
          ];
          dontBuild = true;
          installPhase = ''
            install -Dm755 bin/moq-relay $out/bin/moq-relay
          '';
          meta.mainProgram = "moq-relay";
        };
    in
    {
      packages = forAllSystems (pkgs: {
        moq-relay = moqRelay pkgs;
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.moq-relay;
      });

      devShells = forAllSystems (
        pkgs:
        let
          elixir = pkgs.beamPackages.elixir_1_20;
        in
        {
          default = pkgs.mkShell {
            packages = [
              elixir
              pkgs.beamPackages.erlang
              pkgs.git
              self.packages.${pkgs.stdenv.hostPlatform.system}.moq-relay
            ];

            ERL_AFLAGS = "-kernel shell_history enabled";

            # Hex and Rebar of their own: archives in ~/.mix are compiled for
            # whichever Elixir installed them, and break under another one.
            shellHook = ''
              export MIX_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}/mix/elixir-${elixir.version}"
              mix local.hex --force --if-missing >/dev/null
              mix local.rebar --force --if-missing >/dev/null
            '';
          };
        }
      );
    };
}
