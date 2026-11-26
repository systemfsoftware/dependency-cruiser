#!/usr/bin/env bash
set -euo pipefail

system="${1:?usage: sandbox-conformance.sh <system>}"
linux=false
case "$system" in *-linux) linux=true ;; esac

out() { nix build --no-link --print-out-paths ".#$1"; }
sandboxed="$(out "packages.${system}.dependency-cruiser")/bin/depcruise"
unwrapped="$(out "packages.${system}.dependency-cruiser-unwrapped")/bin/depcruise"
probe_raw="$(out "checks.${system}.sandbox-probe-raw")/bin/sandbox-probe"
probe_boxed="$(out "checks.${system}.sandbox-probe")/bin/sandbox-probe"
probe_required="$(out "checks.${system}.sandbox-probe-required")/bin/sandbox-probe-required"

work="$(mktemp -d)"
canary="$(mktemp "${HOME:?HOME is unset}/dependency-cruiser.canary.XXXXXX")"
outside="$(mktemp -d "$HOME/dcruise-outside.XXXXXX")"
printf 'export const v = 1;\n' > "$outside/a.ts"
portfile="$work/port"
python3 - "$portfile" <<'PY' &
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(8)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
while True:
    conn, _ = s.accept()
    conn.close()
PY
listener=$!
cleanup() { kill "$listener" 2>/dev/null || true; rm -rf "$work" "$outside"; rm -f "$canary"; }
trap cleanup EXIT
until [ -s "$portfile" ]; do sleep 0.1; done
port="$(cat "$portfile")"

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
expect_denied() {
  local out="$1"
  expect_line "$out" NET_DENIED
  expect_line "$out" CANARY_READ_DENIED
  expect_line "$out" 'SECRET=[]'
  expect_line "$out" CWD_READONLY
  expect_line "$out" USR_READ_DENIED
  if [ "$linux" = true ]; then
    expect_line "$out" ETC_READ_DENIED
    expect_line "$out" PROC_READ_DENIED
  fi
}

control="$(SANDBOX_PROBE_SECRET=leak "$probe_raw" "$canary" "$port")"
expect_line "$control" NET_OK
expect_line "$control" CANARY_READ_OK
expect_line "$control" 'SECRET=[leak]'
expect_line "$control" CWD_WRITABLE
expect_line "$control" ETC_READ_OK
expect_line "$control" USR_READ_OK
[ "$linux" = true ] && expect_line "$control" PROC_READ_OK
rm -f .sandbox-probe-write

expect_denied "$(SANDBOX_PROBE_SECRET=leak "$probe_boxed" "$canary" "$port")"
[ ! -e .sandbox-probe-write ] || fail "the optional sandbox wrote into the working directory"
expect_denied "$(SANDBOX_PROBE_SECRET=leak "$probe_required" "$canary" "$port")"
[ ! -e .sandbox-probe-write ] || fail "the required sandbox wrote into the working directory"

set +e
"$sandboxed" --version > version.out 2> version.err
version_rc=$?
"$sandboxed" --config cfg.cjs --output-type err a.ts > box.out 2> box.err; box_rc=$?
"$unwrapped" --config cfg.cjs --output-type err a.ts > raw.out 2> raw.err; raw_rc=$?
"$sandboxed" --config cfg.cjs --output-type err "$outside" > outside.out 2> outside.err; outside_rc=$?
"$unwrapped" --config cfg.cjs --output-type err "$outside" > outside-raw.out 2> outside-raw.err; outside_raw_rc=$?
set -e
[ "$version_rc" -eq 0 ] || fail "the shipped wrapper failed --version (exit $version_rc)"
grep -q '18\.' version.out || fail "the shipped wrapper did not print its version"
[ "$box_rc" -eq 1 ] || fail "a violating project exited $box_rc through the sandbox, want 1"
[ "$raw_rc" -eq 1 ] || fail "a violating project exited $raw_rc unwrapped, want 1"
cmp -s box.out raw.out || fail "the sandboxed stdout differs from the unwrapped stdout"
cmp -s box.err raw.err || fail "the sandboxed stderr differs from the unwrapped stderr"
grep -q 'no-a-to-b' box.out || fail "the violation report is missing from stdout"
[ "$outside_raw_rc" -eq 0 ] || fail "the unwrapped depcruise could not read a path outside the working directory (exit $outside_raw_rc)"
[ "$outside_rc" -ne 0 ] || fail "the sandboxed depcruise reached a path outside the working directory"

unsafe="$work/unsafe directory"
mkdir -p "$unsafe"
set +e
(cd "$unsafe" && "$sandboxed" --version > "$work/unsafe.out" 2> "$work/unsafe.err")
unsafe_rc=$?
set -e
[ "$unsafe_rc" -ne 0 ] || fail "depcruise must refuse an unsafe working directory"
grep -q 'refusing to run' "$work/unsafe.err" || fail "depcruise refused without saying why"

echo "sandbox conformance: ok ($system)"
