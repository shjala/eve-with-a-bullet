#!/bin/bash
#
# Copyright (c) 2026 Zededa, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# run_eve.sh - build and run current EVE under QEMU.
#              Onboards EVE via Adam by default.
#
# Usage: ./run_eve.sh [--repo-root <path>] [--pr <number>] [--test <name>]
#                     [--skip-onboard] [--skip-build] [--clean] [--standalone]
#
#   --repo-root    Path to the EVE repository root (overrides .env file)
#   --pr           GitHub PR number from lf-edge/eve to checkout and test
#   --test         Run a specific test by name and exit (no REPL)
#   --skip-onboard Skip waiting for EVE to onboard (Adam still runs, SSH still waited for)
#   --skip-build   Skip the make live step
#   --clean        Remove the working directory and start fresh
#   --standalone   Download eve-with-a-bullet from GitHub, run from temp dir, clean up
#
# Standalone (pipe-to-bash) example:
#   curl -sL https://raw.githubusercontent.com/shjala/eve-with-a-bullet/main/run.sh \
#     | bash -s -- --standalone --pr XXX --test yyyy
#

set -euo pipefail

# ── standalone bootstrap ──────────────────────────────────────────────────────
# When --standalone is present, download eve-with-a-bullet into a temp dir,
# re-exec run.sh from there with remaining args, and clean up on exit.
# This enables:  curl -sL <raw run.sh URL> | bash -s -- --standalone [args...]
_standalone=false
_passthrough_args=()
for _arg in "$@"; do
    if [[ "$_arg" == "--standalone" ]]; then
        _standalone=true
    else
        _passthrough_args+=("$_arg")
    fi
done

if $_standalone; then
    _EWAB_URL="https://github.com/shjala/eve-with-a-bullet/archive/refs/heads/main.zip"
    _tmpdir=$(mktemp -d /tmp/ewab-standalone.XXXXXX)
    _cleanup_standalone() { rm -rf "$_tmpdir"; }
    trap _cleanup_standalone EXIT INT TERM

    echo "[INFO]  --standalone: downloading eve-with-a-bullet to $_tmpdir ..."
    curl -sL "$_EWAB_URL" -o "$_tmpdir/ewab.zip"
    unzip -q "$_tmpdir/ewab.zip" -d "$_tmpdir"

    # The zip extracts to eve-with-a-bullet-main/
    _extracted="$_tmpdir/eve-with-a-bullet-main"
    if [[ ! -f "$_extracted/run.sh" ]]; then
        echo "[ERROR] run.sh not found in downloaded archive" >&2
        exit 1
    fi

    echo "[INFO]  re-executing from $_extracted/run.sh ..."
    # Run as subprocess (not exec) so our EXIT trap cleans up _tmpdir.
    # Pass _EWAB_STANDALONE so the child knows to clean PR_WORK_DIR too.
    _EWAB_STANDALONE=1 bash "$_extracted/run.sh" "${_passthrough_args[@]}"
    exit $?
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# load env file if it exists
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# ── option parsing ─────────────────────────────────────────────────────────────
SKIP_ONBOARD=false
SKIP_BUILD=false
CLEAN=false
PR_NUMBER=""
RUN_TEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        --pr)
            PR_NUMBER="$2"
            shift 2
            ;;
        --test)
            RUN_TEST="$2"
            shift 2
            ;;
        --skip-onboard) SKIP_ONBOARD=true; shift ;;
        --skip-build)   SKIP_BUILD=true; shift ;;
        --clean)        CLEAN=true; shift ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

# When --pr is given, clone the repo into WORK_DIR and use it as REPO_ROOT.
# This overrides any --repo-root or .env value.
if [[ -n "$PR_NUMBER" ]]; then
    EVE_REPO_URL="https://github.com/lf-edge/eve.git"
    PR_WORK_DIR="${REPO_ROOT:-/tmp}/eve-pr-${PR_NUMBER}"
    mkdir -p "$PR_WORK_DIR"

    PR_EVE_DIR="$PR_WORK_DIR/eve"
    if [[ ! -d "$PR_EVE_DIR/.git" ]]; then
        echo "[INFO]  Cloning lf-edge/eve into $PR_EVE_DIR ..."
        git clone --quiet "$EVE_REPO_URL" "$PR_EVE_DIR"
    fi

    pushd "$PR_EVE_DIR" > /dev/null
    echo "[INFO]  Fetching PR #${PR_NUMBER} ..."
    git fetch --quiet origin "pull/${PR_NUMBER}/head:pr-${PR_NUMBER}"
    git checkout "pr-${PR_NUMBER}" --quiet
    popd > /dev/null

    REPO_ROOT="$PR_EVE_DIR"
    echo "[INFO]  REPO_ROOT set to $REPO_ROOT (PR #${PR_NUMBER})"
fi

if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "[ERROR] REPO_ROOT is required. Provide it via --repo-root," >&2
    echo "        set it in $ENV_FILE, or use --pr <number>" >&2
    exit 1
fi

_LOG="${REPO_ROOT}/run_eve.log"
exec > >(stdbuf -oL tee "$_LOG") 2>&1

# ── configuration ─────────────────────────────────────────────────────────────
EVE_SERIAL="shahshah"
SSH_PORT=2222

WORK_DIR="$REPO_ROOT/dist/out/run-eve-wd"

# ── derived paths ─────────────────────────────────────────────────────────────
SSH_KEY="$WORK_DIR/eve_ssh_key"

ADAM_REPO_URL="https://github.com/shjala/adam.git"
ADAM_COMMIT="4ea055d0a45558d1b72cd6706437ad78306d8e16"
ADAM_DIR="$WORK_DIR/adam"
ADAM_BUILD_LOG="$WORK_DIR/adam_build.log"
ADAM_RUN_LOG="$WORK_DIR/adam_run.log"

QEMU_PID=""
ADAM_PID=""
EVE_RUN_LOG="$WORK_DIR/eve_run.log"

# ── helpers ───────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_step()  { echo ""; echo "[STEP]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

ssh_cmd() {
    ssh -i "$SSH_KEY" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        root@localhost "$@"
}

require_tool() {
    command -v "$1" &>/dev/null || { log_error "Required tool not found: $1"; exit 1; }
}

wait_for_ssh() {
    log_info "Waiting for SSH on port $SSH_PORT..."
    local attempts=0
    while ! ssh_cmd "echo ok" &>/dev/null; do
        sleep 5
        attempts=$((attempts + 1))
        if [ $((attempts % 12)) -eq 0 ]; then
            log_info "  Still waiting for SSH... ($((attempts * 5))s elapsed)"
        fi
    done
    log_info "SSH is up."
}

wait_for_onboard() {
    local timeout=120
    local elapsed=0
    log_info "Waiting for EVE to onboard (checking /run/diag.out, timeout ${timeout}s)..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if ssh_cmd "grep -q 'Connected to EV Controller and onboarded' /run/diag.out 2>/dev/null"; then
            log_info "EVE is onboarded."
            return
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    log_info "WARNING: onboard not detected after ${timeout}s - continuing anyway"
}

kill_qemu() {
    local pidfile="$REPO_ROOT/qemu.pid"
    if [[ -f "$pidfile" ]]; then
        local qpid
        qpid=$(cat "$pidfile")
        if kill -0 "$qpid" 2>/dev/null; then
            log_info "Stopping QEMU (PID $qpid)..."
            kill "$qpid" || true
            sleep 2
        fi
        rm -f "$pidfile"
    fi
}

cleanup() {
    if [ -n "$ADAM_PID" ] && kill -0 "$ADAM_PID" 2>/dev/null; then
        log_info "Stopping Adam (PID $ADAM_PID)..."
        kill "$ADAM_PID" || true
    fi
    kill_qemu
    # When launched via --standalone, clean up the cloned PR repo.
    if [[ "${_EWAB_STANDALONE:-}" == "1" && -n "${PR_WORK_DIR:-}" && -d "${PR_WORK_DIR:-}" ]]; then
        log_info "Cleaning up PR work dir $PR_WORK_DIR ..."
        rm -rf "$PR_WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

log_step "=== Step 1: Prerequisites ==="

require_tool git
require_tool ssh
require_tool scp
require_tool ssh-keygen
require_tool jq
require_tool make
require_tool go

kill_qemu

if $CLEAN && [ -d "$WORK_DIR" ]; then
    log_info "Cleaning working directory $WORK_DIR ..."
    rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR"

log_step "=== Step 2: SSH key setup ==="

if [ ! -f "$SSH_KEY" ]; then
    log_info "Generating SSH key at $SSH_KEY ..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
else
    log_info "SSH key already exists."
fi

mkdir -p "$REPO_ROOT/conf"
cp "${SSH_KEY}.pub" "$REPO_ROOT/conf/authorized_keys"
log_info "Public key installed to $REPO_ROOT/conf/authorized_keys"

log_step "=== Step 3: Set up Adam controller ==="

if [ ! -d "$ADAM_DIR/.git" ]; then
    log_info "Cloning Adam repository to $ADAM_DIR ..."
    git clone --quiet "$ADAM_REPO_URL" "$ADAM_DIR"
else
    log_info "Adam repository already cloned."
fi

pushd "$ADAM_DIR" > /dev/null
git checkout "$ADAM_COMMIT" --quiet
popd > /dev/null

ADAM_BIN="$ADAM_DIR/bin/adam"
ADAM_CERTS="$ADAM_DIR/run/certs/server-tls.crt"

if [ -f "$ADAM_BIN" ] && [ -f "$ADAM_CERTS" ]; then
    log_info "Adam binary and certs already exist - skipping build."
    pushd "$ADAM_DIR" > /dev/null
    EVE_CONFIG="$REPO_ROOT/conf" EVE_SERIAL="$EVE_SERIAL" ./bootstrap.sh --run > "$ADAM_RUN_LOG" 2>&1 &
    ADAM_PID=$!
    popd > /dev/null
else
    log_info "Building Adam -> $ADAM_BUILD_LOG"
    pushd "$ADAM_DIR" > /dev/null
    make > "$ADAM_BUILD_LOG" 2>&1
    popd > /dev/null
    log_info "Adam built."

    pushd "$ADAM_DIR" > /dev/null
    EVE_CONFIG="$REPO_ROOT/conf" EVE_SERIAL="$EVE_SERIAL" OVERWRITE_YES=true ./bootstrap.sh --yes > "$ADAM_RUN_LOG" 2>&1 &
    ADAM_PID=$!
    popd > /dev/null
fi
log_info "Adam started (PID $ADAM_PID) -> $ADAM_RUN_LOG"

log_info "Waiting for Adam to start (and write certs to conf/)..."
until grep -q "Starting adam" "$ADAM_RUN_LOG" 2>/dev/null; do
    sleep 1
done
log_info "Adam is up — conf/root-certificate.pem updated with Adam's rootCA."

log_step "=== Step 4: Build EVE ==="

if $SKIP_BUILD; then
    log_info "Skipping build (--skip-build)."
else
    BUILD_LOG="$WORK_DIR/eve_build.log"
    log_info "Building EVE (make live) -> $BUILD_LOG"
    pushd "$REPO_ROOT" > /dev/null
    make pkgs live > "$BUILD_LOG" 2>&1
    popd > /dev/null
    log_info "Build complete."
fi

log_step "=== Step 5: Boot EVE ==="

log_info "EVE run log -> $EVE_RUN_LOG"
pushd "$REPO_ROOT" > /dev/null
make run TPM=Y QEMU_EVE_SERIAL="$EVE_SERIAL" > "$EVE_RUN_LOG" 2>&1 &
QEMU_PID=$!
popd > /dev/null
log_info "QEMU started (PID $QEMU_PID)"

if $SKIP_ONBOARD; then
    log_info "Skipping onboarding (--skip-onboard)."
fi

log_step "=== Step 6: Inject SSH key into Adam device config ==="

ADAM_DEVICE_DIR="$ADAM_DIR/run/adam/device"
log_info "Waiting for device config to appear..."
DEVICE_CONFIG=""
for i in $(seq 1 30); do
    DEVICE_CONFIG=$(find "$ADAM_DEVICE_DIR" -name "config.json" 2>/dev/null | head -1) || true
    [ -n "$DEVICE_CONFIG" ] && break
    sleep 2
done
if [ -z "$DEVICE_CONFIG" ]; then
    log_error "Device config.json not found under $ADAM_DEVICE_DIR after 60s"
    exit 1
fi
log_info "Found device config: $DEVICE_CONFIG"

SSH_PUB_KEY=$(cat "${SSH_KEY}.pub")
jq --arg key "$SSH_PUB_KEY" '
    .configItems = [
        (.configItems // [] | .[] | select(.key != "debug.enable.ssh")),
        {"key": "debug.enable.ssh", "value": $key}
    ]
' "$DEVICE_CONFIG" > "${DEVICE_CONFIG}.tmp" && mv "${DEVICE_CONFIG}.tmp" "$DEVICE_CONFIG"
log_info "SSH key injected into device config."

log_step "=== Step 7: Wait for SSH and onboarding ==="

wait_for_ssh
if ! $SKIP_ONBOARD; then
    wait_for_onboard
    log_info ""
    log_info "=== EVE is running and onboarded ==="
    log_info ""
fi

log_step "=== Step 8: Build and upload test binary ==="

TESTS_SRC="$SCRIPT_DIR/tests"
TESTS_BIN_LOCAL="$WORK_DIR/eve-tests"
TESTS_BIN_REMOTE="/tmp/eve-tests"

log_info "Building test binary (static linux/amd64)..."
(
    cd "$TESTS_SRC"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$TESTS_BIN_LOCAL" .
) || { log_error "Test binary build failed"; exit 1; }
log_info "Test binary built: $TESTS_BIN_LOCAL"

log_info "Uploading test binary to EVE..."
scp -i "$SSH_KEY" -P "$SSH_PORT" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "$TESTS_BIN_LOCAL" "root@localhost:$TESTS_BIN_REMOTE"
log_info "Uploaded to $TESTS_BIN_REMOTE"

log_info ""
log_info "SSH:  ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
log_info "Logs: $EVE_RUN_LOG"
log_info ""

# ── interactive test REPL ─────────────────────────────────────────────────────

log_step "=== Interactive test runner ==="

RAW_LIST=$(ssh_cmd "$TESTS_BIN_REMOTE --list" 2>/dev/null)
mapfile -t TEST_NAMES < <(echo "$RAW_LIST" | awk '/^  /{print $1}')

if [ ${#TEST_NAMES[@]} -eq 0 ]; then
    log_error "No tests found — running binary directly may help diagnose"
    exit 0
fi

# if --test was given, run it and exit
if [[ -n "$RUN_TEST" ]]; then
    log_info "Running test: $RUN_TEST"
    ssh_cmd "$TESTS_BIN_REMOTE --test $RUN_TEST"
    exit $?
fi

build_and_upload_tests() {
    log_info "Building test binary (static linux/amd64)..."
    (
        cd "$TESTS_SRC"
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$TESTS_BIN_LOCAL" .
    ) || { log_error "Test binary build failed"; return 1; }
    log_info "Test binary built: $TESTS_BIN_LOCAL"

    log_info "Uploading test binary to EVE..."
    scp -i "$SSH_KEY" -P "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$TESTS_BIN_LOCAL" "root@localhost:$TESTS_BIN_REMOTE"
    log_info "Uploaded to $TESTS_BIN_REMOTE"

    RAW_LIST=$(ssh_cmd "$TESTS_BIN_REMOTE --list" 2>/dev/null)
    mapfile -t TEST_NAMES < <(echo "$RAW_LIST" | awk '/^  /{print $1}')
    log_info "Test list refreshed (${#TEST_NAMES[@]} tests)."
}

while true; do
    echo ""
    echo "Available tests:"
    for i in "${!TEST_NAMES[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${TEST_NAMES[$i]}"
    done
    echo "  [a] run all"
    echo "  [b] rebuild and upload tests"
    echo "  [q] quit"
    echo ""
    printf "Select test: "
    read -r selection <>/dev/tty

    case "$selection" in
        q|Q|quit|exit)
            log_info "Exiting test runner."
            break
            ;;
        a|A|all)
            echo ""
            log_info "Running all tests..."
            ssh_cmd "$TESTS_BIN_REMOTE --all" || true
            ;;
        b|B)
            echo ""
            build_and_upload_tests
            ;;
        ''|*[!0-9]*)
            echo "[ERROR] Invalid selection: $selection"
            ;;
        *)
            idx=$((selection - 1))
            if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#TEST_NAMES[@]}" ]; then
                echo "[ERROR] Out of range: $selection"
            else
                name="${TEST_NAMES[$idx]}"
                echo ""
                log_info "Running: $name"
                ssh_cmd "$TESTS_BIN_REMOTE --test $name" || true
            fi
            ;;
    esac
done
