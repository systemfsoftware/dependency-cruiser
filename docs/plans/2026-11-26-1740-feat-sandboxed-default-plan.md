---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
created: 2026-11-26
updated: 2026-11-26
type: feat
title: Ship dependency-cruiser sandboxed by default - Plan
---

# Ship dependency-cruiser sandboxed by default

## Goal Capsule

- **Objective:** `packages.dependency-cruiser` and `packages.default` run the binary inside a hardened sandbox on Linux (`bubblewrap`) and macOS (`sandbox-exec`), and `packages.dependency-cruiser-unwrapped` is the raw binary. CI proves the sandbox by running the binary on `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`.
- **Means:** Add a `mkSandbox` builder that runs the bundled `depcruise` under `--unshare-all --new-session --die-with-parent --clearenv`, binding only `/nix/store`, `/dev`, a tmpfs `/tmp` and a guarded working directory, with the Node runtime's extra needs on macOS (`file-map-executable` on `/nix`, `process-info*`, `/private/tmp`). The working directory is **required**: an unsafe path is refused. Add a conformance probe and a script, and wire them into the existing `nix` job on all three runners.
- **Product authority:** owner design ruling: a CLI tool repository owns its own runtime sandbox and ships it as the default; the sandboxed build is not an opt-in extra, and no consumer policy API is added.
- **Open blockers:** None.
- **Execution profile:** code. `flake.nix`, a probe script, a conformance script, two workflow files.
- **Stop conditions:** conformance green on all three runners; both outputs build and are pushed by `nix-cache-push` on `main`.
- **Tail ownership:** `ce-work` after this plan is written.

---

## Product Contract

### Summary

This fork ships `dependency-cruiser` with its TypeScript parser bundled so it parses a project without a local `node_modules`. Today the flake ships the raw build with full filesystem, network and environment access, on developer workstations and in CI. This plan makes the sandboxed build the package and the default, keeps the raw build as an output, and proves the sandbox in CI by running the binary.

### Requirement

The owner's requirement: each tool repository carries its own hardened sandbox inside its own flake and ships the sandboxed build as its package and `default`; a raw build stays only as an output the sandbox wraps; each repository's conformance check is its own, in its own CI, and it runs the binary. There is no shared sandbox library and no `wrap` forwarder.

### Requirements

- R1. `packages.<system>.dependency-cruiser` and `packages.<system>.default` are the sandboxed build; `packages.<system>.dependency-cruiser-unwrapped` is the raw build.
- R2. The Linux wrapper unshares all namespaces, clears the environment, starts a new session, and binds only `/nix/store`, `/dev`, a tmpfs `/tmp`, and a working directory that passes the `[A-Za-z0-9_/.-]` guard. It does not bind `/proc`, `/etc`, `/usr` or `/lib*`.
- R3. The macOS wrapper uses the Node runtime preset: the native seatbelt baseline plus `file-map-executable` on `/nix`, `process-info*`, and read access to `/private/tmp`, with the `sandbox-exec` deprecation warning filtered from stderr and the exit status preserved.
- R4. The working directory is required: a directory outside the character set, or `/`, `$HOME` or empty, is refused with a message and a non-zero exit.
- R5. A conformance check runs the packaged binary and proves, by running a probe unwrapped and then through the same sandbox builder, that the network is unreachable, the user's home cannot be read, a planted environment secret is absent, and the working directory is read-only; and that the tool's stdout, stderr and exit code pass through unchanged. It also proves the required-working-directory refusal.
- R6. CI runs the conformance check on `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`. `nix-cache-push` on `main` pushes both outputs.

### Scope Boundaries

**In scope:** `flake.nix`, `nix/sandbox-probe.sh`, `scripts/sandbox-conformance.sh`, `.github/workflows/nix.yml`, `.github/workflows/nix-cache-push.yml`.

**Deferred/Out:** the upstream package; the bundled TypeScript; a consumer policy API; a shared library.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. The tool repository owns the sandbox.** No shared library, no `wrap` forwarder. The same `mkSandbox` builds the shipped wrapper and the conformance probe.
- **KTD2. Node preset on macOS, minimal Linux bind.** Linux keeps the same hardened flags as a native binary; macOS adds the three Node allowances the runtime needs.
- **KTD3. Working directory required.** `depcruise` reads the project from the working directory, so an unsafe path is refused rather than silently run without a grant.
- **KTD4. Prove by differential, not by grep.** The probe runs once unwrapped (control) and once through the sandbox; pass-through is proven on the real binary by comparing its output and exit code against the unwrapped one.
- **KTD5. Lift the AppArmor restriction in Linux CI.** Stock Ubuntu runners set `kernel.apparmor_restrict_unprivileged_userns=1`; the job sets it to `0` before running. This is a runner prerequisite, not a weakening of the sandbox.

### Assumptions

- A1. The conformance fixture project needs no `node_modules`; the bundled TypeScript resolves the imports.
- A2. `macos-latest` is `aarch64-darwin` and runs `sandbox-exec`.

### Measured Answers To The Open Questions

These were measured, not assumed.

1. **Can a GitHub `ubuntu-latest` runner and an `ubuntu-24.04-arm` runner run `bwrap --unshare-all`?**
   - On stock settings, **no**. Both images set `kernel.apparmor_restrict_unprivileged_userns=1`. An unprivileged `bubblewrap` fails with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`. The Ubuntu-packaged `bubblewrap` 0.11.1 succeeds on `ubuntu-latest` only because Ubuntu ships it setuid/AppArmor-profiled; on `ubuntu-24.04-arm` the packaged 0.9.0 fails the same way.
   - After `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, **yes**: `--unshare-all`, `--clearenv` and `--tmpfs /tmp` all exit `0` on both runners.
   - Measured on `ubuntu-latest` (image `ubuntu-26.04`, `x86_64`) and `ubuntu-24.04-arm` (image `ubuntu-24.04-arm`, `aarch64`).
2. **Do checkout paths in CI and in `wt` worktrees stay within `[A-Za-z0-9_/.-]`?**
   - CI: `GITHUB_WORKSPACE=/home/runner/work/<repo>/<repo>`, measured on both Linux runners. All characters are in the set.
   - `wt` worktrees: 194 worktree directories under a working tree, none with a character outside the set, and no branch name containing `@`, `+` or a space.
3. **Which environment variables does the tool need?**
   - None. `depcruise --version`, `depcruise --info` and a real TypeScript run all succeed under `env -i`: `--info` reports the bundled `typescript@6.0.3`, and a two-file project cruises two modules. The launcher resolves `node` by an absolute store path, so `PATH` is not required either. The wrapper still sets `HOME`, `TMPDIR`, `LANG` and `PATH` for a Node-runtime convention.
4. **Which other repositories consume this flake?**
   - None on a default branch: a code search for `filename:flake.nix dependency-cruiser` across the organisation returns no result. The fork is newer than the tool's consumers.

---

## Implementation Units

### U1. Add the sandboxed package

- **Goal:** The shipped package is the hardened sandbox on Linux and macOS, and the raw build is a separate output.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none
- **Files:** `flake.nix`
- **Approach:** One `mkSandbox { name, binary, cwdMode }` builds a Linux wrapper (`bubblewrap`, `--unshare-all --new-session --die-with-parent --clearenv`, the minimal binds and the guarded required cwd) and a macOS wrapper (Node-preset seatbelt profile, guarded cwd subpath, stderr filter, exit-status preservation). `dependency-cruiser` and `default` use it around `dependency-cruiser-unwrapped`; the wrapper's executable is `depcruise`.
- **Verification:** `nix eval` for all four systems.

### U2. Add the probe and the conformance script

- **Goal:** A check that runs the binary and proves the five properties plus the required-cwd refusal.
- **Requirements:** R5
- **Dependencies:** U1
- **Files:** `nix/sandbox-probe.sh`, `scripts/sandbox-conformance.sh`
- **Approach:** The probe uses only shell builtins. `checks.<system>.sandbox-probe-raw` is the probe; `checks.<system>.sandbox-probe` is the same probe through `mkSandbox`. The script asserts the control is permissive and the sandboxed run is not, compares the real binary's output and exit code against the unwrapped binary on a violating project, and asserts a directory with a space is refused.
- **Verification:** the script exits `0` for `x86_64-linux`.

### U3. Wire CI and the cache push

- **Goal:** The conformance check is green on all three runners, and both outputs are pushed on `main`.
- **Requirements:** R6
- **Dependencies:** U2
- **Files:** `.github/workflows/nix.yml`, `.github/workflows/nix-cache-push.yml`
- **Approach:** The `nix` job evaluates every output on every system, lifts the AppArmor restriction on Linux, builds both outputs, runs the conformance check, and keeps the existing TypeScript steps running against the sandboxed binary. The cache push adds `dependency-cruiser-unwrapped`.
- **Verification:** all three conformance jobs green; the cache push run on `main` succeeds.

---

## Verification Contract

| # | Command | Applies | Done signal |
|---|---|---|---|
| 1 | `./scripts/sandbox-conformance.sh x86_64-linux` | U2 | `sandbox conformance: ok (x86_64-linux)` |
| 2 | `nix eval --raw .#packages.aarch64-darwin.dependency-cruiser.drvPath` | U1 | prints a store path |
| 3 | `nix build .#dependency-cruiser .#dependency-cruiser-unwrapped` | U1 | both build |
| 4 | `nix-cache-push` on `main` | U3 | run concludes success; both paths served |

## Definition of Done

- **Global:** R1–R6 hold; the conformance check runs the binary on both Linux architectures and on macOS and is green; both outputs are pushed.
- **Per-unit:** U1 wrapper shipped and evaluated; U2 probe and script green; U3 workflows updated.
