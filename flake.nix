{
  description = "Coherent memory-pressure tuning (zram/zswap + PSI-armed systemd-oomd + sysctls) for a given RAM level, as one small NixOS module.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.system-manager.url = "github:numtide/system-manager";
  inputs.system-manager.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };

      levelsData = import ./levels.nix;
      inherit (levelsData) levelNames levels;

      # Single source of truth for the RAM-size boundaries: generated
      # straight from levels.nix, never duplicated as separate magic
      # numbers in the detection script.
      boundaryLines = lib.concatMapStringsSep "\n"
        (name: "${toString levels.${name}.ramMiB} ${name}")
        levelNames;

      mkDetectLevel = pkgs: pkgs.writeShellApplication {
        name = "detect-level";
        runtimeInputs = [ pkgs.gawk ];
        text = ''
          mem_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
          mem_mib=$(( mem_kib / 1024 ))

          boundaries="
          ${boundaryLines}
          "

          chosen=""
          last_name=""
          while read -r mib name; do
            [ -z "$mib" ] && continue
            last_name="$name"
            if [ "$mem_mib" -le "$mib" ]; then
              chosen="$name"
              break
            fi
          done <<EOF
          $boundaries
          EOF

          if [ -z "$chosen" ]; then
            # Actual RAM exceeds every anchor (bigger than 128G) --
            # cap at the largest level rather than leaving it unset.
            chosen="$last_name"
          fi

          echo "Detected: $mem_mib MiB total RAM (/proc/meminfo MemTotal)"
          echo "Nearest nixram level (rounded UP to the next anchor, never down): $chosen"
          echo
          echo "This is a 'detect once, paste once' tool, not a live auto-detector:"
          echo "run it on the target machine, then paste the line below into your"
          echo "NixOS configuration and commit it like any other hardware fact."
          echo
          echo "    services.nixram.level = \"$chosen\";"
        '';
      };
    in
    {
      nixosModules.nixram = import ./modules/default.nix;
      nixosModules.default = self.nixosModules.nixram;

      # For non-NixOS hosts (CachyOS et al.) applying config via
      # numtide/system-manager instead of a real NixOS rebuild -- see
      # system-manager/default.nix for what this backend can and can't do
      # relative to the NixOS module above.
      systemManagerModules.nixram = import ./system-manager/default.nix;
      systemManagerModules.default = self.systemManagerModules.nixram;

      apps = forAllSystems (system: {
        detect-level = {
          type = "app";
          program = "${mkDetectLevel (pkgsFor system)}/bin/detect-level";
        };
      });

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit nixpkgs;
          nixramModule = self.nixosModules.nixram;
          systemManagerModule = self.systemManagerModules.nixram;
          systemManagerLib = system-manager.lib;
        }
      );
    };
}
