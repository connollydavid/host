#!/usr/bin/env bash
# The host entrance. Installs the toolset and scaffolds an agentic project:
#
#   curl -fsSL https://raw.githubusercontent.com/connollydavid/host/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/connollydavid/host/main/install.sh | bash -s -- agentic-acme
#
# Two phases with a seam between them, because installing a toolset and creating a
# project fail in different ways and folding them into one step means a bootstrap
# can run against a partial toolchain. The install phase puts verified binaries on
# PATH and records what landed. The create phase scaffolds and hands over to an
# agent harness. Nothing is scaffolded until the whole install set is verified.
#
# Specified in host-install.allium. Every exit below is one of that spec's
# outcomes; changing one changes the spec.
#
# bash 3.2 only. macOS ships 3.2.57 at /bin/bash and has never updated it, so no
# associative arrays, no mapfile, no ${var^^}, no ${var:i:n}.

set -euo pipefail

MANIFEST_URL=${HOST_MANIFEST_URL:-https://raw.githubusercontent.com/connollydavid/host/main/install-manifest}
BIN_DIR=${HOST_BIN_DIR:-$HOME/.local/bin}
RECEIPT_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/host
RECEIPT=$RECEIPT_DIR/install-receipt

# The allowlist, ordered by GitHub star count. Ordering is a data signal rather
# than a recommendation, and the counts are never shown: a menu that displayed
# them would read as an endorsement.
HARNESS_BINARIES="opencode claude codex qwen cursor-agent pi"
HARNESS_LABELS="opencode|Claude Code|Codex CLI|Qwen Code|Cursor Agent|Pi Agent"

# Exit codes. These are the spec's outcomes, and a wrapper can act on them.
EX_ENV=1        # missing_prerequisite, unsupported_platform, manifest_untrusted
EX_NAME=3       # name_required
EX_REFUSED=4    # name_refused, target_exists
EX_FETCH=5      # fetch_failed
EX_DIGEST=6     # digest_mismatch

# Whether a controlling terminal can actually be used. Probed by OPENING it, not
# by testing it: /dev/tty reports readable in a container, under nohup and in CI
# while being impossible to open, so `[ -r /dev/tty ]` passes and the next write
# fails. Under `set -e` that failure replaced the specific exit code with a bare
# 1, which is exactly the case the name backstop exists to serve.
HAVE_TTY=0
if { : > /dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { code=$1; shift; warn "install.sh: $*"; exit "$code"; }

# ---------------------------------------------------------------- prerequisites

# Checked before any network work, so a machine missing a tool is told that
# rather than a download error twenty seconds later.
SHA_CMD=
find_prerequisites() {
    command -v git >/dev/null 2>&1 \
        || die $EX_ENV "needs git on PATH. Install git, then run this again."
    command -v curl >/dev/null 2>&1 \
        || die $EX_ENV "needs curl on PATH. Install curl, then run this again."

    if command -v sha256sum >/dev/null 2>&1; then
        SHA_CMD=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        SHA_CMD="shasum -a 256"
    else
        die $EX_ENV "needs sha256sum or shasum to verify downloads. Install either, then run this again."
    fi
}

# ------------------------------------------------------------------- platform

PLATFORM=
detect_platform() {
    os=$(uname -s)
    arch=$(uname -m)

    case $os in
        Darwin)                  os_key=darwin  ;;
        Linux)                   os_key=linux   ;;
        MINGW*|MSYS*|CYGWIN*)    os_key=windows ;;
        *) die $EX_ENV "does not serve $os. It serves macOS, Linux and Git Bash on Windows." ;;
    esac

    case $arch in
        x86_64|amd64)   arch_key=amd64 ;;
        arm64|aarch64)  arch_key=arm64 ;;
        *) die $EX_ENV "does not serve $arch on $os. It serves amd64 and arm64." ;;
    esac

    # Rosetta: an arm64 mac running this under translation reports x86_64, and
    # would be handed the slower binary for the rest of its life.
    if [ "$os_key" = darwin ] && [ "$arch_key" = amd64 ]; then
        if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
            arch_key=arm64
        fi
    fi

    PLATFORM="$os_key-$arch_key"
}

# ------------------------------------------------------------------- install

# All-or-nothing is implemented rather than asserted: every binary is fetched to a
# staging directory and checked there, and nothing is moved into place until the
# whole set has matched. A mismatch on the last one leaves the machine untouched.
STAGE=
# Always succeeds: this runs on the way out of every exit path, and a trap whose
# last command fails is a way to lose the exit code the caller was given.
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; return 0; }
trap cleanup EXIT

INSTALLED_LINES=
install_toolset() {
    STAGE=$(mktemp -d)
    manifest=$STAGE/manifest

    # --proto '=https' --tlsv1.2 is the transport trust root. The manifest is
    # served from the same repository over the same TLS as this script, so
    # fetching it crosses no boundary the operator had not already crossed.
    curl -fsSL --proto '=https' --tlsv1.2 -o "$manifest" "$MANIFEST_URL" \
        || die $EX_FETCH "could not fetch the install manifest from $MANIFEST_URL"

    revision=$(awk '$1 == "template-revision" { print $2; exit }' "$manifest")
    [ -n "$revision" ] \
        || die $EX_FETCH "the install manifest carries no template-revision line; it is truncated or not a manifest"

    # Count what this platform expects before fetching any of it, so "every entry
    # placed" is checked against a number the manifest states rather than against
    # however many happened to arrive. The SAME awk filter feeds the loop below:
    # counting with awk and iterating with `grep '^binary '` made the two disagree
    # about a line with leading whitespace, because awk strips it when splitting
    # fields and grep does not, and the install then died reporting a count it
    # could not explain.
    entries=$(awk -v p="$PLATFORM" '$1 == "binary" && $4 == p' "$manifest")
    expected=$(printf '%s' "$entries" | grep -c . || true)
    [ "$expected" -gt 0 ] \
        || die $EX_FETCH "the install manifest lists no binaries for $PLATFORM"

    say "Installing the host toolset for $PLATFORM (template revision $revision)."

    placed=0
    while read -r _kind name version platform url digest; do
        [ "$platform" = "$PLATFORM" ] || continue

        target=$STAGE/$name
        curl -fsSL --proto '=https' --tlsv1.2 -o "$target" "$url" \
            || die $EX_FETCH "could not download $name $version for $PLATFORM from $url"

        got=$($SHA_CMD "$target" | awk '{print $1}')
        if [ "$got" != "$digest" ]; then
            warn "install.sh: $name $version for $PLATFORM does not match its recorded digest."
            warn "  expected $digest"
            warn "  got      $got"
            warn "  Nothing has been installed. These are not the bytes the manifest names."
            exit $EX_DIGEST
        fi

        chmod +x "$target"
        placed=$((placed + 1))
        INSTALLED_LINES="$INSTALLED_LINES$name $version $PLATFORM $digest
"
    done <<EOF
$entries
EOF

    # A backstop rather than a branch any input reaches: the count and the loop now
    # read one filter, so this can only fire if a later change splits them again.
    [ "$placed" -eq "$expected" ] \
        || die $EX_FETCH "expected $expected binaries for $PLATFORM and verified $placed; nothing has been installed"

    # Every byte is identified. Only now does anything reach PATH.
    mkdir -p "$BIN_DIR"
    for f in "$STAGE"/*; do
        case $(basename "$f") in
            manifest) continue ;;
        esac
        mv "$f" "$BIN_DIR/$(basename "$f")"
    done

    write_receipt "$revision" "$expected"
    say "Installed $expected binaries to $BIN_DIR."
}

# The receipt is machine-scoped, not project-scoped, because the binaries are: they
# land in one shared bin directory, so a per-project record would describe state it
# does not own and would disagree with its sibling the moment a second project was
# created. It is also written before any project name exists, which a per-project
# path could not be.
write_receipt() {
    revision=$1
    count=$2
    mkdir -p "$RECEIPT_DIR"
    {
        echo "# host install receipt. Written by install.sh; read it to see what this machine has."
        echo "# Re-verify offline: rebuild any component from its pinned source and recorded"
        echo "# toolchain and compare the digest below. That is the durable trust root."
        echo ""
        echo "installed-at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "template-revision $revision"
        echo "bin-dir $BIN_DIR"
        echo "count $count"
        echo ""
        printf '%s' "$INSTALLED_LINES" | while read -r n v p d; do
            [ -n "$n" ] && echo "binary $n $v $p $d"
        done
    } > "$RECEIPT"
}

# ---------------------------------------------------------------------- PATH

configure_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) return 0 ;;
    esac

    line="export PATH=\"$BIN_DIR:\$PATH\""
    case $(basename "${SHELL:-/bin/sh}") in
        zsh)  config=$HOME/.zshrc ;;
        bash) config=$HOME/.bashrc ;;
        fish) config=${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish
              line="fish_add_path $BIN_DIR" ;;
        *)    config=$HOME/.profile ;;
    esac

    mkdir -p "$(dirname "$config")"
    printf '\n# host toolset\n%s\n' "$line" >> "$config"
    say "Added $BIN_DIR to PATH in $config. Open a new shell, or run: $line"

    # This shell needs it now, for the scaffold step below.
    PATH="$BIN_DIR:$PATH"
    export PATH
}

# ---------------------------------------------------------------------- name

NAME=
resolve_name() {
    candidate=${1:-}

    if [ -z "$candidate" ]; then
        if [ "$HAVE_TTY" = 1 ]; then
            printf 'Project name (becomes agentic-<name>): ' > /dev/tty
            read -r candidate < /dev/tty || candidate=
        fi
    fi

    # No name and nothing to ask on. A machine-parseable line naming the missing
    # field, rather than a default nobody chose.
    [ -n "$candidate" ] \
        || die $EX_NAME "name required: pass one as an argument, for example | bash -s -- acme"

    case $candidate in
        agentic-*) ;;
        *) candidate="agentic-$candidate" ;;
    esac

    # Checked after prefixing, so the rule is stated once and holds over what is
    # actually created.
    case $candidate in
        *[!a-zA-Z0-9_-]*)
            die $EX_REFUSED "refuses the name '$candidate': use letters, digits, hyphen and underscore only." ;;
    esac

    [ "$candidate" != "agentic-host" ] \
        || die $EX_REFUSED "refuses the name 'agentic-host': that is this methodology's own development host. Choose another name."

    NAME=$candidate
}

# -------------------------------------------------------------------- create

scaffold() {
    [ ! -e "$NAME" ] \
        || die $EX_REFUSED "refuses to scaffold into '$NAME': it already exists here."

    command -v host-lifecycle >/dev/null 2>&1 \
        || die $EX_ENV "cannot find host-lifecycle after installing it. Check that $BIN_DIR is on PATH."

    host-lifecycle init "$NAME" \
        || die $EX_REFUSED "host-lifecycle init failed for '$NAME'; nothing further was done."

    say "Scaffolded $NAME."
}

# ------------------------------------------------------------------- harness

# Probed by name from the allowlist. There is no cross-vendor variable announcing
# an installed harness, so `command -v` is the only honest test.
HARNESS=
detect_harness() {
    found=""
    count=0
    for b in $HARNESS_BINARIES; do
        if command -v "$b" >/dev/null 2>&1; then
            found="$found $b"
            count=$((count + 1))
        fi
    done
    found=${found# }

    if [ "$count" -eq 0 ]; then
        say ""
        say "No agent harness found. $NAME is scaffolded and ready."
        say "Install one (opencode or claude, for example), then: cd $NAME"
        exit 0
    fi

    if [ "$count" -eq 1 ]; then
        HARNESS=$found
        return 0
    fi

    if [ "$HAVE_TTY" != 1 ]; then
        # Several available and no way to ask. Taking the first would be a silent
        # choice among things the operator may care about, so it is not made.
        say ""
        say "$NAME is scaffolded and ready. Several harnesses are installed:$found"
        say "Start one yourself: cd $NAME"
        exit 0
    fi

    say ""
    say "$NAME is scaffolded. Which harness should continue the bringup?"
    i=0
    for b in $found; do
        i=$((i + 1))
        printf '  %d) %s\n' "$i" "$(harness_label "$b")"
    done

    while :; do
        printf 'Choose 1-%d: ' "$i" > /dev/tty
        read -r choice < /dev/tty || choice=
        case $choice in
            ''|*[!0-9]*) warn "  Enter a number between 1 and $i." ; continue ;;
        esac
        if [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
            HARNESS=$(echo "$found" | cut -d' ' -f"$choice")
            return 0
        fi
        warn "  Enter a number between 1 and $i."
    done
}

harness_label() {
    idx=0
    for b in $HARNESS_BINARIES; do
        idx=$((idx + 1))
        if [ "$b" = "$1" ]; then
            echo "$HARNESS_LABELS" | cut -d'|' -f"$idx"
            return 0
        fi
    done
    echo "$1"
}

# ----------------------------------------------------------------------- main

main() {
    find_prerequisites
    detect_platform
    install_toolset
    configure_path

    resolve_name "${1:-}"
    scaffold
    detect_harness

    say ""
    say "Handing $NAME to $(harness_label "$HARNESS"). When it exits you will be back here."
    say "  cd $NAME"
    cd "$NAME"
    exec "$HARNESS"
}

main "$@"
