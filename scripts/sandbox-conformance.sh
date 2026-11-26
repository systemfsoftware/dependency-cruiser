#!/usr/bin/env bash
set -euo pipefail

system="${1:?usage: sandbox-conformance.sh <system>}"

out() { nix build --no-link --print-out-paths ".#$1"; }
sandboxed="$(out "packages.${system}.dependency-cruiser")/bin/depcruise"
unwrapped="$(out "packages.${system}.dependency-cruiser-unwrapped")/bin/depcruise"
probe_raw="$(out "checks.${system}.sandbox-probe-raw")/bin/sandbox-probe"
probe_boxed="$(out "checks.${system}.sandbox-probe")/bin/sandbox-probe"

work="$(mktemp -d)"
canary="$(mktemp "${HOME:?HOME is unset}/dependency-cruiser.canary.XXXXXX")"
cleanup() { rm -rf "$work"; rm -f "$canary"; }
trap cleanup EXIT
cd "$work"
printf 'import { v } from "./b.ts";\nexport const x = v;\n' > a.ts
printf 'export const v = 1;\n' > b.ts
cat > cfg.cjs <<'EOF'
module.exports = {
  forbidden: [
    { name: "no-a-to-b", severity: "error", from: { path: "^a\\.ts$" }, to: { path: "^b\\.ts$" } },
  ],
  options: {},
};
EOF

fail() { echo "sandbox conformance: FAIL: $*" >&2; exit 1; }
expect_line() {
  local out="$1" line="$2"
  grep -qxF "$line" <<<"$out" || fail "expected '$line' in: $(tr '\n' ' ' <<<"$out")"
}

control="$(SANDBOX_PROBE_SECRET=leak "$probe_raw" "$canary")"
expect_line "$control" NET_OK
expect_line "$control" CANARY_READ_OK
expect_line "$control" 'SECRET=[leak]'
expect_line "$control" CWD_WRITABLE
rm -f .sandbox-probe-write

boxed="$(SANDBOX_PROBE_SECRET=leak "$probe_boxed" "$canary")"
expect_line "$boxed" NET_DENIED
expect_line "$boxed" CANARY_READ_DENIED
expect_line "$boxed" 'SECRET=[]'
expect_line "$boxed" CWD_READONLY
[ ! -e .sandbox-probe-write ] || fail "the sandbox wrote into the working directory"

set +e
"$sandboxed" --config cfg.cjs --output-type err a.ts > box.out 2> box.err; box_rc=$?
"$unwrapped" --config cfg.cjs --output-type err a.ts > raw.out 2> raw.err; raw_rc=$?
set -e
[ "$box_rc" -eq 1 ] || fail "a violating project exited $box_rc through the sandbox, want 1"
[ "$raw_rc" -eq 1 ] || fail "a violating project exited $raw_rc unwrapped, want 1"
cmp -s box.out raw.out || fail "the sandboxed stdout differs from the unwrapped stdout"
cmp -s box.err raw.err || fail "the sandboxed stderr differs from the unwrapped stderr"
grep -q 'no-a-to-b' box.out || fail "the violation report is missing from stdout"

unsafe="$work/unsafe directory"
mkdir -p "$unsafe"
set +e
(cd "$unsafe" && "$sandboxed" --version > "$work/unsafe.out" 2> "$work/unsafe.err")
unsafe_rc=$?
set -e
[ "$unsafe_rc" -ne 0 ] || fail "depcruise must refuse an unsafe working directory"
grep -q 'refusing to run' "$work/unsafe.err" || fail "depcruise refused without saying why"

echo "sandbox conformance: ok ($system)"
