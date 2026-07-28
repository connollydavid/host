#!/usr/bin/env bash
# Integration tests for install.sh. Every case drives the real script end to end
# against mocked surroundings, so a test that passes proves the script's own
# control flow rather than a helper beside it.
#
# What is mocked, and why each one has to be: `uname` (the machine under test is
# one machine and the script serves six), `curl` (the network, and the only way to
# make a download fail on purpose), `git` and `host-lifecycle` (presence, and the
# scaffold), and the harness binaries (presence, and the handover). `sha256sum` is
# NOT mocked: the digest check is the property under test, so it runs for real
# over real bytes.
#
# Run: ./tests/install-test.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../install.sh

# macOS ships shasum rather than sha256sum, and the suite has to run there: it is
# the only place bash 3.2 can be exercised, which is the script's hardest constraint.
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA="shasum -a 256"
else echo "no sha256 tool available" >&2; exit 1
fi

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad()  {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
}

# Assertion helpers. `A && ok || bad` reads as if-then-else and is not: when the
# condition holds but `ok` returns non-zero, `bad` runs too and the suite reports a
# failure that never happened. Every assertion goes through one of these instead.
want_rc()      { if [ "$RC" -eq "$1" ]; then ok "$2"; else bad "$2" "rc=$RC out=$OUT"; fi; }
want_out()     { case $OUT in *"$1"*) ok "$2" ;; *) bad "$2" "out=$OUT" ;; esac; }
want_exists()  { if [ -e "$1" ]; then ok "$2"; else bad "$2" "$1 is absent"; fi; }
want_absent()  { if [ ! -e "$1" ]; then ok "$2"; else bad "$2" "$1 is present"; fi; }
want_exec()    { if [ -x "$1" ]; then ok "$2"; else bad "$2" "$1 is not executable"; fi; }
want_grep()    { if grep -q "$1" "$2"; then ok "$3"; else bad "$3" "no match for $1"; fi; }
want_eq()      { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "got $1, wanted $2"; fi; }

# Build a sandbox: a mock PATH, a fixture "remote", and an isolated HOME.
# Returns with $SANDBOX set and the caller's cwd inside its work directory.
SANDBOX=
new_sandbox() {
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/bin" "$SANDBOX/remote" "$SANDBOX/home" "$SANDBOX/work"

cat > "$SANDBOX/bin/uname" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
-s) printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
-m) printf '%s\n' "${MOCK_UNAME_M:-x86_64}" ;;
*)  printf '%s\n' "${MOCK_UNAME_S:-Linux}" ;;
esac
EOF

# Serves $SANDBOX/remote by URL basename. MOCK_CURL_FAIL names a basename that
# must fail, which is how a download is made to die without a network.
cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=; url=
while [ $# -gt 0 ]; do
case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *)  url=$1; shift ;;
esac
done
base=${url##*/}
[ "$base" = "${MOCK_CURL_FAIL:-}" ] && exit 22
[ -f "$MOCK_REMOTE/$base" ] || exit 22
cp "$MOCK_REMOTE/$base" "$out"
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/git"

# Scaffolds by making the directory, which is all the script depends on.
cat > "$SANDBOX/bin/host-lifecycle" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = init ] || exit 2
mkdir -p "$2" && printf 'scaffolded\n' > "$2/.host"
EOF

chmod +x "$SANDBOX/bin/uname" "$SANDBOX/bin/curl" "$SANDBOX/bin/git" "$SANDBOX/bin/host-lifecycle"

# Link in only the real tools the script legitimately uses. The sandbox PATH is
# then this directory ALONE: with /usr/bin on it, removing the mock git left the
# real one visible and the "no git" case silently tested nothing.
for real in bash env sha256sum shasum awk grep sed cut tr wc date find \
            mktemp cp mv rm mkdir chmod basename dirname cat printf; do
    src=$(command -v "$real" 2>/dev/null) || continue
    ln -sf "$src" "$SANDBOX/bin/$real"
done

cd "$SANDBOX/work" || exit 1
}

drop_sandbox() {
cd / || exit 1
if [ -n "$SANDBOX" ]; then rm -rf "$SANDBOX"; fi
SANDBOX=
}

# Put a working binary into the fixture remote and echo its real digest. These are
# executable rather than inert bytes on purpose: install.sh puts its bin directory
# at the front of PATH, so whatever it installs SHADOWS the mock of the same name.
# Inert fixtures made every post-install step fail, which is the script behaving
# correctly against a harness that was lying to it.
publish() {
component=$1
platform=$2
case $component in
    host-lifecycle)
        cat > "$MOCK_REMOTE/$component-$platform" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = init ] || exit 2
mkdir -p "$2" && printf 'scaffolded\n' > "$2/.host"
EOF
        ;;
    *)
        printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCK_REMOTE/$component-$platform"
        ;;
esac
$SHA "$MOCK_REMOTE/$component-$platform" | awk '{print $1}'
}

# Write a manifest for one platform covering the two install-set components.
write_manifest() {
platform=$1
hl=$(publish host-lifecycle "$platform")
hn=$(publish host-lint "$platform")
{
    echo "# fixture manifest"
    echo "template-revision abc1234"
    echo ""
    echo "binary host-lifecycle 0.47.0 $platform https://example.invalid/host-lifecycle-$platform $hl"
    echo "binary host-lint 0.16.1 $platform https://example.invalid/host-lint-$platform $hn"
} > "$MOCK_REMOTE/install-manifest"
}

# Run install.sh inside the sandbox. Echoes nothing; sets RC and OUT.
RC=0; OUT=
run_install() {
OUT=$(
    PATH="$SANDBOX/bin" \
    HOME="$SANDBOX/home" \
    XDG_DATA_HOME="$SANDBOX/home/.data" \
    HOST_BIN_DIR="$SANDBOX/home/.local/bin" \
    HOST_MANIFEST_URL="https://example.invalid/install-manifest" \
    MOCK_REMOTE="$SANDBOX/remote" \
    MOCK_UNAME_S="${MOCK_UNAME_S:-Linux}" \
    MOCK_UNAME_M="${MOCK_UNAME_M:-x86_64}" \
    MOCK_CURL_FAIL="${MOCK_CURL_FAIL:-}" \
    SHELL=/bin/bash \
    bash "$SCRIPT" "$@" 2>&1 < /dev/null
)
RC=$?
}

echo "install.sh integration tests"


# --------------------------------------------------------------- prerequisites

prerequisites_absent_refuses() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
rm "$SANDBOX/bin/git"
run_install acme
want_rc 1 "missing git exits 1"
want_out "needs git" "the message names git"
drop_sandbox

# ------------------------------------------------------------------- platform

}

unknown_os_refuses() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
MOCK_UNAME_S=SunOS run_install acme
want_rc 1 "an unknown OS exits 1"
want_out "does not serve SunOS" "the message names the OS"
unset MOCK_UNAME_S
drop_sandbox

}

unknown_arch_refuses() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
MOCK_UNAME_M=riscv64 run_install acme
want_rc 1 "an unknown architecture exits 1"
want_out "riscv64" "the message names the architecture"
unset MOCK_UNAME_M
drop_sandbox

# --------------------------------------------------------------------- fetch

}

manifest_unreachable_refuses() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
MOCK_CURL_FAIL=install-manifest run_install acme
want_rc 5 "an unreachable manifest exits 5"
unset MOCK_CURL_FAIL
drop_sandbox

}

manifest_without_this_platform_refuses() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest darwin-arm64
run_install acme   # machine is linux-amd64; the manifest covers only darwin-arm64
want_rc 5 "a manifest without this platform exits 5"
want_out "no binaries for linux-amd64" "the message names the platform"
drop_sandbox

}

download_failure_installs_nothing() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
MOCK_CURL_FAIL=host-lint-linux-amd64 run_install acme
want_rc 5 "a failed binary download exits 5"
want_absent "$SANDBOX/home/.local/bin/host-lifecycle" "all-or-nothing: the binary that DID download is not installed"
unset MOCK_CURL_FAIL
drop_sandbox

# -------------------------------------------------------------------- digest

}

digest_mismatch_installs_nothing() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
# Corrupt the second binary's bytes after the manifest recorded its digest.
printf 'tampered\n' > "$MOCK_REMOTE/host-lint-linux-amd64"
run_install acme
want_rc 6 "a digest mismatch exits 6"
want_out "does not match its recorded digest" "the message says the bytes are wrong"
want_absent "$SANDBOX/home/.local/bin/host-lifecycle" "all-or-nothing: a mismatch on the second leaves the first uninstalled"
want_absent "$SANDBOX/home/.data/host/install-receipt" "a refused install writes no receipt claiming a toolset"
drop_sandbox

# ---------------------------------------------------------------------- name

}

name_required_without_a_tty() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install            # no argument, and stdin is /dev/null so there is no TTY
want_rc 3 "no name and no usable TTY exits 3"
want_out "name required" "the line is machine-parseable and names the field"
drop_sandbox

}

malformed_name_refused() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install 'acme; rm -rf /'
want_rc 4 "a name with shell metacharacters is refused with 4"
drop_sandbox

}

traversal_name_refused() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install '../escape'
want_rc 4 "a path-traversal name is refused with 4"
drop_sandbox

}

reserved_name_refused() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install host
want_rc 4 "the reserved name is refused with 4, after prefixing"
want_out "agentic-host" "the message names the reserved name"
drop_sandbox

}

existing_target_refused() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
mkdir -p "$SANDBOX/work/agentic-acme"
run_install acme
want_rc 4 "an existing target is refused with 4"
want_out "already exists" "the message says the directory is there"
drop_sandbox

# ------------------------------------------------------------------ happy path

}

clean_run_installs_and_scaffolds() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install acme
want_rc 0 "a clean run with no harness exits 0"
want_exec "$SANDBOX/home/.local/bin/host-lifecycle" "host-lifecycle lands on PATH, executable"
want_exec "$SANDBOX/home/.local/bin/host-lint" "host-lint lands on PATH, executable"
want_exists "$SANDBOX/work/agentic-acme" "the bare name is prefixed to agentic-acme"
want_out "No agent harness found" "no harness prints an actionable line and succeeds"

R=$SANDBOX/home/.data/host/install-receipt
want_exists "$R" "the receipt is written"
want_grep '^template-revision abc1234$' "$R" "the receipt records the template revision"
want_eq "$(grep -c '^binary ' "$R")" 2 "the receipt records both binaries"
want_grep "^binary host-lint 0.16.1 linux-amd64 " "$R" "a receipt line carries name, version, platform and digest"
drop_sandbox

# The receipt is machine-scoped, so a second project does not fork the record.
}

receipt_is_machine_scoped() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
run_install one
run_install two
want_rc 0 "a second project on the same machine installs cleanly"
want_eq "$(find "$SANDBOX/home/.data" -name install-receipt | wc -l | tr -d ' ')" 1 "two projects share one machine-scoped receipt"
drop_sandbox

# A manifest line carrying leading whitespace is read the same way by the counter
# and by the loop. They once disagreed (awk strips it when splitting fields, grep
# does not), and the install died reporting "expected 2 and verified 1" over a
# manifest that was entirely well formed as far as any reader could tell.
}

indented_manifest_line_is_consistent() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
sed 's|^binary host-lint|  binary host-lint|' "$MOCK_REMOTE/install-manifest" > "$MOCK_REMOTE/m.tmp"
mv "$MOCK_REMOTE/m.tmp" "$MOCK_REMOTE/install-manifest"
run_install acme
want_rc 0 "an indented manifest line does not break the run"
want_exec "$SANDBOX/home/.local/bin/host-lint" "an indented manifest line is counted and installed consistently"
drop_sandbox

# ------------------------------------------------------------------- harness

}

single_harness_is_launched() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
cat > "$SANDBOX/bin/opencode" <<'HARNESS'
#!/usr/bin/env bash
printf 'opencode ran in %s\n' "$(basename "$PWD")"
HARNESS
chmod +x "$SANDBOX/bin/opencode"
run_install acme
want_rc 0 "a single-harness run exits 0"
want_out "opencode ran in agentic-acme" "a single harness is auto-selected and exec'd inside the project"
drop_sandbox

}

several_harnesses_without_a_tty_defers() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest linux-amd64
for h in opencode claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/$h"; chmod +x "$SANDBOX/bin/$h"; done
run_install acme
want_rc 0 "a multi-harness run with no TTY still exits 0"
want_out "Several harnesses are installed" "it refuses to choose for the operator and says so"
drop_sandbox

# ------------------------------------------------------------------- rosetta

}

rosetta_is_served_arm64() {
new_sandbox; MOCK_REMOTE=$SANDBOX/remote; write_manifest darwin-arm64
cat > "$SANDBOX/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[ "${2:-}" = sysctl.proc_translated ] && { printf '1\n'; exit 0; }
exit 1
EOF
chmod +x "$SANDBOX/bin/sysctl"
MOCK_UNAME_S=Darwin MOCK_UNAME_M=x86_64 run_install acme
want_rc 0 "a mac under Rosetta is served arm64, not the translated x86_64"
unset MOCK_UNAME_S MOCK_UNAME_M
drop_sandbox
}

# Every case is a named function so an obligation can name the test that
# discharges it, and so a reader can run one case by name.
prerequisites_absent_refuses
unknown_os_refuses
unknown_arch_refuses
manifest_unreachable_refuses
manifest_without_this_platform_refuses
download_failure_installs_nothing
digest_mismatch_installs_nothing
name_required_without_a_tty
malformed_name_refused
traversal_name_refused
reserved_name_refused
existing_target_refused
clean_run_installs_and_scaffolds
receipt_is_machine_scoped
indented_manifest_line_is_consistent
single_harness_is_launched
several_harnesses_without_a_tty_defers
rosetta_is_served_arm64

echo ""
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
