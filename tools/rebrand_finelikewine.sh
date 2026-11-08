#!/usr/bin/env bash
#
# FinELikEWinE recovery builder  (OrangeFox fox_12.1 base)
#
# Usage:
#   ./build_finelikewine.sh lancelot            # build (source must already be synced)
#   ./build_finelikewine.sh lancelot --sync     # sync OrangeFox source first (big download), then build
#   ./build_finelikewine.sh lancelot --sync-only   # only sync, then stop (so you can run the rebrand script)
#   ./build_finelikewine.sh lancelot --clean    # 'make clean' before building
#   TREE_URL=https://github.com/you/your_merlin_tree ./build_finelikewine.sh merlin
#
# Environment overrides:
#   FOX_DIR     where the OrangeFox source lives   (default: ~/fox_12.1)
#   FWINE_OUT   where finished files are copied    (default: ~/finelikewine_out)
#               (NOT called OUT_DIR on purpose: Android's own build uses OUT_DIR for its output folder)
#   TREE_URL    git URL of the device tree         (default for lancelot is set below)
#   TREE_BRANCH branch of the device tree          (default: recovery-12.1)
#   SYNC_BRANCH OrangeFox manifest branch          (default: 12.1)
#   PATCH_FILE  a .patch (git am) applied right after the tree is cloned the first time
#
# NOTE: BoardConfig.mk in the tree hard-codes DEVICE_PATH := device/xiaomi/<codename>,
#       so the tree MUST live at $FOX_DIR/device/xiaomi/<codename>. This script does that.

DEVICE="${1:-}"
shift || true

DO_SYNC=0
SYNC_ONLY=0
DO_CLEAN=0
for a in "$@"; do
    case "$a" in
        --sync)  DO_SYNC=1 ;;
        --sync-only) DO_SYNC=1; SYNC_ONLY=1 ;;
        --clean) DO_CLEAN=1 ;;
        *) echo "Unknown option: $a"; exit 2 ;;
    esac
done

if [ -z "$DEVICE" ]; then
    sed -n '2,24p' "$0"
    exit 2
fi

FOX_DIR="${FOX_DIR:-$HOME/fox_12.1}"
FWINE_OUT="${FWINE_OUT:-$HOME/finelikewine_out}"
SYNC_BRANCH="${SYNC_BRANCH:-12.1}"
TREE_BRANCH="${TREE_BRANCH:-recovery-12.1}"
BRAND="FinELikEWinE"
JOBS="$(nproc 2>/dev/null || echo 4)"

# default tree URL per device (merlin: you must supply your own)
if [ -z "${TREE_URL:-}" ]; then
    case "$DEVICE" in
        lancelot) TREE_URL="https://github.com/mt6768-place/recovery_device_xiaomi_lancelot" ;;
        *)        TREE_URL="" ;;
    esac
fi

DEVICE_DIR="$FOX_DIR/device/xiaomi/$DEVICE"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- preflight
info "Preflight"
command -v git >/dev/null || die "git is not installed"

mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
[ "$mem_gb" -lt 12 ] && echo "WARNING: only ${mem_gb} GB RAM detected; builds like this are happier with 16 GB (add swap if it gets OOM-killed)."

mkdir -p "$(dirname "$FOX_DIR")"
free_gb=$(df -P --output=avail -BG "$(dirname "$FOX_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9')
[ -n "$free_gb" ] && [ "$free_gb" -lt 60 ] && echo "WARNING: only ${free_gb} GB free; a sync + build can use 40-80 GB."

# ---------------------------------------------------------------- sync
if [ "$DO_SYNC" = "1" ]; then
    info "Syncing OrangeFox $SYNC_BRANCH into $FOX_DIR (this takes a long time)"
    [ -d "$FOX_DIR/build" ] && die "$FOX_DIR already looks synced. Remove --sync, or delete the folder first."
    command -v aria2c >/dev/null || echo "WARNING: aria2 not installed (sudo apt install aria2) - sync script may fail."
    SYNC_TMP="$(dirname "$FOX_DIR")/OrangeFox_sync"
    mkdir -p "$SYNC_TMP"
    [ -d "$SYNC_TMP/sync" ] || git clone https://gitlab.com/OrangeFox/sync.git "$SYNC_TMP/sync" || die "could not clone the sync scripts"
    ( cd "$SYNC_TMP/sync" && ./orangefox_sync.sh --branch "$SYNC_BRANCH" --path "$FOX_DIR" ) || die "orangefox_sync.sh failed"
    if [ "$SYNC_ONLY" = "1" ]; then
        info "Sync finished. Next: rebrand (optional), then run this script again without --sync-only."
        exit 0
    fi
fi

[ -f "$FOX_DIR/build/envsetup.sh" ] || die "No OrangeFox source at $FOX_DIR. Re-run with --sync, or set FOX_DIR."

# ---------------------------------------------------------------- device tree
info "Device tree -> $DEVICE_DIR"
if [ -d "$DEVICE_DIR" ]; then
    echo "Tree already present, leaving it untouched (your local edits are safe)."
else
    [ -n "$TREE_URL" ] || die "No tree at $DEVICE_DIR and no TREE_URL given for '$DEVICE'."
    mkdir -p "$(dirname "$DEVICE_DIR")"
    git clone -b "$TREE_BRANCH" "$TREE_URL" "$DEVICE_DIR" || die "could not clone $TREE_URL"
    if [ -n "${PATCH_FILE:-}" ]; then
        [ -f "$PATCH_FILE" ] || die "PATCH_FILE not found: $PATCH_FILE"
        git -C "$DEVICE_DIR" -c user.name=finelikewine -c user.email=build@localhost am "$PATCH_FILE" \
            || die "patch did not apply (run 'git -C $DEVICE_DIR am --abort' and check the tree/branch)"
        echo "Applied $PATCH_FILE"
    fi
fi
[ -f "$DEVICE_DIR/vendorsetup.sh" ] || die "$DEVICE_DIR/vendorsetup.sh missing - is this the right folder?"
grep -q "device/xiaomi/$DEVICE" "$DEVICE_DIR/BoardConfig.mk" 2>/dev/null \
    || echo "WARNING: BoardConfig.mk does not mention device/xiaomi/$DEVICE - check DEVICE_PATH in it."

# ---------------------------------------------------------------- environment
info "Setting up build environment"
cd "$FOX_DIR" || die "cannot cd to $FOX_DIR"

# Android's build treats OUT_DIR as its output folder; make sure a stray one cannot redirect it.
unset OUT_DIR
# vendorsetup.sh silently skips ALL OrangeFox settings unless this is exported
# BEFORE envsetup.sh runs (and it is also sourced explicitly below).
export FOX_BUILD_DEVICE="$DEVICE"
export ALLOW_MISSING_DEPENDENCIES=true
export LC_ALL="C"

# envsetup.sh is not 'set -e/-u' safe, and its exit status is only that of the last vendorsetup.sh
# it happened to source - so judge success by whether 'lunch' got defined, not by the exit code.
# Its output is kept (not thrown away) so a real failure is visible in the log.
ENV_LOG="$(mktemp)"
# shellcheck disable=SC1091
source build/envsetup.sh > "$ENV_LOG" 2>&1
env_rc=$?
if ! declare -F lunch >/dev/null 2>&1; then
    echo "---- last 40 lines of the build/envsetup.sh output ----"
    tail -40 "$ENV_LOG"
    die "build/envsetup.sh did not define 'lunch' (exit code $env_rc) - see the output above"
fi
if [ "$env_rc" -ne 0 ]; then
    echo "note: build/envsetup.sh exited with code $env_rc, but 'lunch' is available - continuing."
    echo "      (last lines of its output, in case one of them matters:)"
    tail -5 "$ENV_LOG" | sed 's/^/      /'
fi
# shellcheck disable=SC1090
source "$DEVICE_DIR/vendorsetup.sh"
# brand name in the build/zip name even if the tree's vendorsetup.sh does not set it
export FOX_BUILD_TYPE="${FOX_BUILD_TYPE:-$BRAND}"

echo "OF_MAINTAINER   = ${OF_MAINTAINER:-<unset>}"
echo "FOX_VARIANT     = ${FOX_VARIANT:-<unset>}"
echo "FOX_BUILD_TYPE  = ${FOX_BUILD_TYPE:-<unset>}"
[ -n "${OF_MAINTAINER:-}" ] || die "OrangeFox vars were not applied (vendorsetup.sh did nothing). Check FOX_BUILD_DEVICE."

# ---------------------------------------------------------------- build
info "lunch twrp_${DEVICE}-eng"
lunch "twrp_${DEVICE}-eng" || die "lunch failed (check the error above; usually a missing/misnamed makefile or variable)"

if [ "$DO_CLEAN" = "1" ]; then
    info "make clean"
    make clean
fi

info "mka adbd recoveryimage  (-j$JOBS)"
mka adbd recoveryimage -j"$JOBS" || die "build failed - scroll up for the first 'error:' line"

# ---------------------------------------------------------------- collect
info "Collecting results"
PROD="$FOX_DIR/out/target/product/$DEVICE"
IMG="$PROD/recovery.img"
[ -f "$IMG" ] || die "recovery.img not found in $PROD"

mkdir -p "$FWINE_OUT"
STAMP="$(date +%Y%m%d)"
OUT_IMG="$FWINE_OUT/${BRAND}-${DEVICE}-${STAMP}.img"
cp -f "$IMG" "$OUT_IMG"

ZIP="$(ls -t "$PROD"/OrangeFox*.zip "$PROD"/*"$BRAND"*.zip 2>/dev/null | head -1)"
OUT_ZIP=""
if [ -n "$ZIP" ]; then
    OUT_ZIP="$FWINE_OUT/${BRAND}-${DEVICE}-${STAMP}-fox-installer.zip"
    cp -f "$ZIP" "$OUT_ZIP"
fi

# size sanity check against the partition size declared in BoardConfig.mk
PART_SIZE="$(grep -E '^BOARD_RECOVERYIMAGE_PARTITION_SIZE' "$DEVICE_DIR/BoardConfig.mk" | tail -1 | sed 's/.*:= *//; s/ *#.*//')"
IMG_SIZE="$(stat -c %s "$OUT_IMG")"
echo "Image size      : $IMG_SIZE bytes"
echo "Declared limit  : ${PART_SIZE:-unknown} bytes (BoardConfig.mk)"
if [ -n "$PART_SIZE" ] && [ "$IMG_SIZE" -gt "$PART_SIZE" ] 2>/dev/null; then
    echo "WARNING: image is larger than the declared partition size. Do NOT flash it."
fi
echo "Also confirm the REAL partition size on the phone:"
echo "    adb shell blockdev --getsize64 /dev/block/by-name/recovery"

( cd "$FWINE_OUT" && sha256sum "$(basename "$OUT_IMG")" ${OUT_ZIP:+"$(basename "$OUT_ZIP")"} | tee "${BRAND}-${DEVICE}-${STAMP}.sha256" )

info "DONE"
echo "  $OUT_IMG"
[ -n "$OUT_ZIP" ] && echo "  $OUT_ZIP"
echo
echo "Flash (bootloader unlocked, from fastboot mode):"
echo "  fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img   # stock vbmeta"
echo "  fastboot flash recovery $(basename "$OUT_IMG")"
echo "  fastboot reboot recovery"
