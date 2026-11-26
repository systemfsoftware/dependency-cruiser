{
  description = "dependency-cruiser, built with its TypeScript parser bundled";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = f:
        lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      mkDependencyCruiser = pkgs:
        pkgs.buildNpmPackage {
          pname = "dependency-cruiser";
          version = (builtins.fromJSON (builtins.readFile ./package.json)).version;
          src = self;
          npmDepsHash = "sha256-RYKAHJ23EWvksIPnMmAbdNG3jzfn/5vJROyoW6g90iw=";
          dontNpmBuild = true;
          npmFlags = [ "--ignore-scripts" ];
          meta = {
            description = "Validate and visualize dependencies";
            homepage = "https://github.com/sverweij/dependency-cruiser";
            license = lib.licenses.mit;
            mainProgram = "depcruise";
          };
        };

      cwdGuard = ''
        safe_cwd() {
          case "$1" in
            "" | / | "$HOME") return 1 ;;
            *[!A-Za-z0-9_/.-]*) return 1 ;;
          esac
          return 0
        }
      '';

      seatbelt = pkgs: pkgs.writeText "dependency-cruiser.sb" ''
        (version 1)
        (deny default)
        (allow process-fork)
        (allow process-exec)
        (allow process-info* (target same-sandbox))
        (allow signal (target same-sandbox))
        (allow sysctl-read)
        (allow file-read-metadata)
        (allow mach-lookup
            (global-name "com.apple.system.notification_center")
            (global-name "com.apple.system.logger")
            (global-name "com.apple.distributed_notifications@Uv3")
            (global-name "com.apple.CoreServices.coreservicesd")
            (global-name "com.apple.FSEvents"))
        (allow file-read-data (literal "/"))
        (allow file-read*
            (subpath "/nix")
            (subpath "/usr/lib")
            (subpath "/usr/share")
            (subpath "/System")
            (subpath "/Library")
            (subpath "/private/etc")
            (subpath "/private/tmp")
            (subpath "/private/var/db/dyld")
            (subpath "/private/var/db/timezone"))
        (allow file-map-executable (subpath "/nix"))
        (allow file-read* (subpath "/dev/fd"))
        (allow file-read* file-write* file-ioctl
            (literal "/dev/tty")
            (regex #"^/dev/ttys[0-9]+$"))
        (allow file-read* file-write*
            (literal "/dev/null")
            (literal "/dev/zero")
            (literal "/dev/random")
            (literal "/dev/urandom"))
        (allow file-write* (subpath "/private/tmp"))
      '';

      mkSandbox = pkgs: { name, binary, cwdMode }:
        let
          nodePath = lib.makeBinPath [ pkgs.nodejs ];
          requireCwd = cwdMode == "required";
          linuxCwd = if requireCwd then ''
            real="$(pwd -P)"
            safe_cwd "$real" || {
              echo "${name}: refusing to run: working directory '$real' is not a plain path in [A-Za-z0-9_/.-]" >&2
              exit 1
            }
            binds=(--ro-bind "$real" "$real" --chdir "$real")
            [ "$real" != "$PWD" ] && safe_cwd "$PWD" && binds+=(--ro-bind "$real" "$PWD")
          '' else ''
            binds=()
            safe_cwd "$PWD" && binds=(--ro-bind "$PWD" "$PWD" --chdir "$PWD")
          '';
          darwinCwd = if requireCwd then ''
            real="$(pwd -P)"
            safe_cwd "$real" || {
              echo "${name}: refusing to run: working directory '$real' is not a plain path in [A-Za-z0-9_/.-]" >&2
              exit 1
            }
            cwdRules=" (subpath \"$real\")"
            [ "$real" != "$PWD" ] && safe_cwd "$PWD" && cwdRules="$cwdRules (subpath \"$PWD\")"
          '' else ''
            cwdRules=""
            safe_cwd "$PWD" && cwdRules=" (subpath \"$PWD\")"
            real="$(pwd -P)"
            [ "$real" != "$PWD" ] && safe_cwd "$real" && cwdRules="$cwdRules (subpath \"$real\")"
          '';
        in
        if pkgs.stdenv.hostPlatform.isLinux then
          pkgs.writeShellScriptBin name ''
            ${cwdGuard}
            ${linuxCwd}
            exec ${pkgs.bubblewrap}/bin/bwrap \
              --ro-bind /nix/store /nix/store \
              --dev /dev --tmpfs /tmp \
              --unshare-all --new-session --die-with-parent --clearenv \
              --setenv HOME /tmp --setenv TMPDIR /tmp --setenv LANG C.UTF-8 --setenv PATH ${nodePath} \
              "''${binds[@]}" \
              -- ${binary} "$@"
          ''
        else if pkgs.stdenv.hostPlatform.isDarwin then
          pkgs.writeShellScriptBin name ''
            ${cwdGuard}
            ${darwinCwd}
            profile=$(cat ${seatbelt pkgs})
            profile="$profile
            (allow file-read*$cwdRules)"
            export TMPDIR=/private/tmp
            err=$(mktemp "$TMPDIR/${name}.XXXXXX")
            /usr/bin/env -i HOME="$TMPDIR" TMPDIR="$TMPDIR" LANG=C.UTF-8 PATH=${nodePath} \
              /usr/bin/sandbox-exec -p "$profile" -- ${binary} "$@" 2>"$err"
            status=$?
            grep -vF 'sandbox-exec is deprecated' "$err" >&2
            rm -f "$err"
            exit $status
          ''
        else
          throw "${name}: no sandbox for ${pkgs.stdenv.hostPlatform.system}";

      probe = pkgs: pkgs.writeShellScriptBin "sandbox-probe" (builtins.readFile ./nix/sandbox-probe.sh);
    in
    {
      packages = forEachSystem (pkgs:
        let
          unwrapped = mkDependencyCruiser pkgs;
          sandboxed = mkSandbox pkgs {
            name = "depcruise";
            binary = "${unwrapped}/bin/depcruise";
            cwdMode = "required";
          };
        in
        {
          dependency-cruiser = sandboxed;
          dependency-cruiser-unwrapped = unwrapped;
          default = sandboxed;
        });

      checks = forEachSystem (pkgs:
        let
          raw = probe pkgs;
        in
        {
          sandbox-probe-raw = raw;
          sandbox-probe = mkSandbox pkgs {
            name = "sandbox-probe";
            binary = "${raw}/bin/sandbox-probe";
            cwdMode = "optional";
          };
        });
    };
}
