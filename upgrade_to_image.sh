#!/bin/bash
#
# Copyright (c) 2026 Zededa, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# upgrade_to_image.sh - build EVE master, boot it, onboard, and upgrade to a
#                       user-supplied rootfs image.
#
# Usage: ./upgrade_to_image.sh [--repo-root <path>] [--skip-build] [--clean]
#                              <rootfs-image>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# load env file if it exists
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

# ── option parsing ─────────────────────────────────────────────────────────────
SKIP_BUILD=false
CLEAN=false
UPGRADE_IMAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --clean)      CLEAN=true; shift ;;
        -*)           echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
        *)            UPGRADE_IMAGE="$1"; shift ;;
    esac
done

if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "[ERROR] REPO_ROOT is required. Provide it via --repo-root" >&2
    echo "        or set it in $ENV_FILE" >&2
    exit 1
fi

_LOG="${REPO_ROOT}/upgrade_to_image.log"
exec > >(stdbuf -oL tee "$_LOG") 2>&1

if [ -z "$UPGRADE_IMAGE" ]; then
    echo "Usage: $0 [--repo-root <path>] [--skip-build] [--clean] <rootfs-image>" >&2
    exit 1
fi

UPGRADE_IMAGE="$(cd "$(dirname "$UPGRADE_IMAGE")" && pwd)/$(basename "$UPGRADE_IMAGE")"

if [ ! -f "$UPGRADE_IMAGE" ]; then
    echo "[ERROR] Rootfs image not found: $UPGRADE_IMAGE" >&2
    exit 1
fi

# ── configuration ─────────────────────────────────────────────────────────────
EVE_SERIAL="shahshah"
SSH_PORT=2222

EVE_REPO_URL="https://github.com/lf-edge/eve.git"

# Working directory
WORK_DIR="$PWD/dist/out/upgrade-wd"

# ── derived paths ─────────────────────────────────────────────────────────────

EVE_DIR="$WORK_DIR/eve"
SSH_KEY="$WORK_DIR/eve_ssh_key"

ADAM_REPO_URL="https://github.com/shjala/adam.git"
ADAM_COMMIT="4ea055d0a45558d1b72cd6706437ad78306d8e16"
ADAM_DIR="$WORK_DIR/adam"
ADAM_BUILD_LOG="$WORK_DIR/adam_build.log"
ADAM_RUN_LOG="$WORK_DIR/adam_run.log"

QEMU_PID=""
ADAM_PID=""
EVE_RUN_LOG=""

# ── helpers ───────────────────────────────────────────────────────────────────

log_info()  { echo "[INFO]  $*"; }
log_step()  { echo ""; echo "[INFO]  $*"; }
log_error() { echo "[ERROR] $*" >&2; }

ssh_cmd() {
    ssh -i "$SSH_KEY" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        root@localhost "$@"
}

scp_to_eve() {
    ssh_cmd "cat > $2" < "$1"
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

reboot_and_wait() {
    log_info "Rebooting EVE..."
    ssh_cmd "reboot" || true
    sleep 15
    wait_for_ssh
}

kill_qemu() {
    local pidfile="$EVE_DIR/qemu.pid"
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
}
trap cleanup EXIT INT TERM

log_step "=== Step 1: Prerequisites ==="

require_tool git
require_tool ssh
require_tool ssh-keygen
require_tool jq

if $CLEAN && [ -d "$WORK_DIR" ]; then
    log_info "Cleaning working directory $WORK_DIR ..."
    rm -rf "$WORK_DIR"
fi

mkdir -p "$WORK_DIR"

log_step "=== Step 2: Fetch EVE source ==="

if [ ! -d "$EVE_DIR/.git" ]; then
    log_info "Cloning EVE repository to $EVE_DIR ..."
    git clone --quiet "$EVE_REPO_URL" "$EVE_DIR"
else
    log_info "EVE repository already cloned."
fi

pushd "$EVE_DIR" > /dev/null
log_info "Checking out master..."
git fetch --quiet
git checkout master
git pull --quiet
popd > /dev/null

log_step "=== Step 3: SSH key setup ==="

if [ ! -f "$SSH_KEY" ]; then
    log_info "Generating SSH key at $SSH_KEY ..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
else
    log_info "SSH key already exists."
fi

mkdir -p "$EVE_DIR/conf"
cp "${SSH_KEY}.pub" "$EVE_DIR/conf/authorized_keys"
log_info "Public key installed to $EVE_DIR/conf/authorized_keys"

log_step "=== Step 4: Set up Adam controller ==="

if [ ! -d "$ADAM_DIR/.git" ]; then
    log_info "Cloning Adam repository to $ADAM_DIR ..."
    git clone --quiet "$ADAM_REPO_URL" "$ADAM_DIR"
else
    log_info "Adam repository already cloned."
fi

pushd "$ADAM_DIR" > /dev/null
git checkout "$ADAM_COMMIT"
popd > /dev/null

ADAM_BIN="$ADAM_DIR/bin/adam"
ADAM_CERTS="$ADAM_DIR/run/certs/server-tls.crt"

if [ -f "$ADAM_BIN" ] && [ -f "$ADAM_CERTS" ]; then
    log_info "Adam binary and certs already exist - skipping build"
    log_info "Running bootstrap.sh --run → $ADAM_RUN_LOG"
    pushd "$ADAM_DIR" > /dev/null
    EVE_CONFIG="$EVE_DIR/conf" EVE_SERIAL="$EVE_SERIAL" ./bootstrap.sh --run > "$ADAM_RUN_LOG" 2>&1 &
    ADAM_PID=$!
    popd > /dev/null
else
    log_info "Building Adam (commit $ADAM_COMMIT) → $ADAM_BUILD_LOG"
    pushd "$ADAM_DIR" > /dev/null
    make > "$ADAM_BUILD_LOG" 2>&1
    popd > /dev/null
    log_info "Adam built."

    log_info "Running bootstrap.sh --yes → $ADAM_RUN_LOG"
    pushd "$ADAM_DIR" > /dev/null
    EVE_CONFIG="$EVE_DIR/conf" EVE_SERIAL="$EVE_SERIAL" OVERWRITE_YES=true ./bootstrap.sh --yes > "$ADAM_RUN_LOG" 2>&1 &
    ADAM_PID=$!
    popd > /dev/null
fi
log_info "Adam started (PID $ADAM_PID)"

log_info "Waiting for Adam to start..."
until grep -q "Starting adam" "$ADAM_RUN_LOG" 2>/dev/null; do
    sleep 1
done
log_info "Adam is up."

log_step "=== Step 4a: Inject SSH key into Adam device config ==="

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
log_info "Injecting SSH public key into device config (debug.enable.ssh)"

jq --arg key "$SSH_PUB_KEY" '
    .configItems = [
        (.configItems // [] | .[] | select(.key != "debug.enable.ssh")),
        {"key": "debug.enable.ssh", "value": $key}
    ]
' "$DEVICE_CONFIG" > "${DEVICE_CONFIG}.tmp" && mv "${DEVICE_CONFIG}.tmp" "$DEVICE_CONFIG"

log_info "Device config updated with SSH key."

log_step "=== Step 5: Build EVE (master) ==="

EVE_DIST_DIR="$EVE_DIR/dist/amd64/current"
if [ -d "$EVE_DIST_DIR" ] && [ -n "$(ls -A "$EVE_DIST_DIR" 2>/dev/null)" ]; then
    log_info "EVE already built ($EVE_DIST_DIR) - skipping build"
elif $SKIP_BUILD; then
    log_info "Skipping build (--skip-build)"
else
    BUILD_LOG="$WORK_DIR/eve_build.log"
    log_info "Build output → $BUILD_LOG"
    pushd "$EVE_DIR" > /dev/null
    make pkg/pillar live > "$BUILD_LOG" 2>&1
    popd > /dev/null
fi

log_step "=== Step 6: Boot EVE and wait for onboarding ==="

kill_qemu

EVE_RUN_LOG="$WORK_DIR/eve_run.log"
log_info "EVE run log → $EVE_RUN_LOG"
pushd "$EVE_DIR" > /dev/null
make run TPM=Y QEMU_EVE_SERIAL="$EVE_SERIAL" > "$EVE_RUN_LOG" 2>&1 &
QEMU_PID=$!
popd > /dev/null
log_info "QEMU started (PID $QEMU_PID)"

wait_for_ssh
wait_for_onboard

log_step "=== Step 7: Reboot after onboarding ==="

reboot_and_wait

log_step "=== Step 8: Upgrade - flash rootfs to other partition ==="

CURPART=$(ssh_cmd "eve exec pillar zboot curpart")
OTHERPART=$([ "$CURPART" = "IMGA" ] && echo "IMGB" || echo "IMGA")
log_info "Current partition: $CURPART  →  target partition: $OTHERPART"

OTHER_PARTDEV=$(ssh_cmd "lsblk -rno NAME,PARTLABEL | awk -v p='$OTHERPART' '\$2==p {print \"/dev/\" \$1}'")
if [ -z "$OTHER_PARTDEV" ]; then
    log_error "Could not find block device for partition $OTHERPART"
    exit 1
fi
log_info "Other partition device: $OTHER_PARTDEV"

log_info "Uploading rootfs image to EVE (this may take a while)..."
scp_to_eve "$UPGRADE_IMAGE" "/persist/rootfs-upgrade.img"

log_info "Writing rootfs to $OTHER_PARTDEV ..."
ssh_cmd "dd if=/persist/rootfs-upgrade.img of=$OTHER_PARTDEV bs=4M && sync"
ssh_cmd "rm -f /persist/rootfs-upgrade.img"

log_info "Setting $OTHERPART state to 'updating'..."
ssh_cmd "eve exec pillar zboot set_partstate $OTHERPART updating"

log_step "=== Step 9: Reboot into upgraded partition ==="

reboot_and_wait

log_step "=== Step 10: Verify upgrade ==="

NEW_CURPART=$(ssh_cmd "eve exec pillar zboot curpart")
log_info "Now running on partition: $NEW_CURPART"

if [ "$NEW_CURPART" = "$OTHERPART" ]; then
    log_info "Upgrade successful - EVE booted into $NEW_CURPART"
else
    log_error "Upgrade may have failed - expected $OTHERPART but got $NEW_CURPART"
    exit 1
fi

log_info ""
log_info "=== Upgrade complete ==="
log_info ""
log_info "To SSH into the device:"
log_info "  ssh -i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@localhost"
