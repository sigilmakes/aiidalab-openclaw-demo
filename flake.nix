{
    description = "AiiDALab, SLURM, Bifrost and OpenClaw demo on a single-node k3s cluster";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        openclaw = {
            url = "github:openclaw/nix-openclaw/4e5f44465d367839780be6f6111a1ab7ff6e315b";
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };

    outputs =
        { self, nixpkgs, openclaw }:
        let
            system = "x86_64-linux";
            pkgs = nixpkgs.legacyPackages.${system};

            exampleSite = {
                STORAGE_CLASS = "local-path";
                NODE_ADDRESS = "192.0.2.10";
                CLAW_HOSTNAME = "claw.example.com";
                AIIDA_HOSTNAME = "aiida.example.com";
                PORTAL_DOMAIN = "example.com";
                TUNNEL_ID = "00000000-0000-0000-0000-000000000000";
                ACCESS_TEAM = "example-team";
                ACCESS_AUD_CLAW = "0000000000000000000000000000000000000000000000000000000000000000";
                ACCESS_AUD_AIIDA = "0000000000000000000000000000000000000000000000000000000000000000";
                ACCESS_AUD_PORTAL = "0000000000000000000000000000000000000000000000000000000000000000";
                VERTEX_PROJECT = "example-project";
                VERTEX_REGION_CLAUDE = "europe-west1";
                VERTEX_REGION_GEMINI = "europe-west2";
            };

            exampleManifests = import ./nix/render.nix { inherit pkgs; } {
                source = ./manifests;
                substitutions = exampleSite;
                openclawImage = "sandbox.local/openclaw:2026.10.7";
            };

            manifestCheck = pkgs.runCommand "aiidalab-openclaw-demo-check-manifests" {
                nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
            } ''
                python3 ${./checks/manifests.py} ${exampleManifests}
                touch $out
            '';
        in
        {
            nixosModules.default =
                { ... }:
                {
                    imports = [ ./module.nix ];
                    _module.args.openclawFlake = openclaw;
                };

            packages.${system} = {
                openclaw-image = pkgs.callPackage ./images/openclaw.nix { inherit openclaw; };
                slurm-image = pkgs.callPackage ./images/slurm.nix { };
                ingress-switch = pkgs.callPackage ./packages/ingress-switch.nix { manifests = exampleManifests; };
            };

            checks.${system} = {
                default = manifestCheck;
                secrets = pkgs.runCommand "aiidalab-openclaw-demo-check-secrets" {
                    nativeBuildInputs = [ pkgs.gitleaks ];
                } ''
                    gitleaks detect --no-git --source ${./.} --redact --exit-code 1 --no-banner
                    touch $out
                '';
            };
        };
}
