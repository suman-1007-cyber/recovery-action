#!/usr/bin/env bash
#
# Put your own banner / splash / logo images into a synced OrangeFox source tree.
#
#   bash tools/apply_branding.sh --list  [FOX_DIR]    show candidate images (path + size) in the source
#   bash tools/apply_branding.sh --apply [FOX_DIR]    copy images listed in branding/images.map
#   bash tools/apply_branding.sh --revert [FOX_DIR]   restore the .orig backups
#
# branding/images.map  (one mapping per line, '#' = comment):
#     <file in branding/>  |  <path of the file to replace, relative to FOX_DIR>  |  [resize]
#   e.g.  splash_1080x2340.png | bootable/recovery/gui/theme/common/<existing splash>.png
#
# Rules (so a typo can't wreck the build):
#   * only EXISTING files are replaced (a backup  <file>.orig  is kept next to each)
#   * destination must be inside bootable/recovery, vendor/recovery or device/
#   * the picture must have the same pixel size as the file it replaces, unless the line ends with
#     "| resize" (then ImageMagick 'convert' scales it; preinstalled on GitHub's Ubuntu runners)
# Problems are reported as warnings; the script never aborts the build.

MODE=""; FOX_DIR=""
for a in "$@"; do
    case "$a" in
        --list|--apply|--revert) MODE="$a" ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) FOX_DIR="$a" ;;
    esac
done
[ -n "$MODE" ] || { sed -n '2,22p' "$0"; exit 2; }
FOX_DIR="${FOX_DIR:-$HOME/fox_12.1}"
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAND_DIR="${BRAND_DIR:-$TOOLS/../branding}"
MAP="$BRAND_DIR/images.map"

warn() { echo "::warning::$*" 2>/dev/null; echo "WARNING: $*"; }

png_size() { # prints "WxH" of a PNG, or nothing
    python3 - "$1" <<'EOF' 2>/dev/null
import struct, sys
d = open(sys.argv[1], 'rb').read(24)
if d[:8] == b'\x89PNG\r\n\x1a\n':
    w, h = struct.unpack('>II', d[16:24]); print('%dx%d' % (w, h))
EOF
}

[ -d "$FOX_DIR" ] || { echo "ERROR: $FOX_DIR not found"; exit 0; }

if [ "$MODE" = "--list" ]; then
    echo "Candidate images in $FOX_DIR (name contains splash/logo/banner/fox/orange):"
    found=0
    while IFS= read -r f; do
        s="$(png_size "$f")"
        printf '  %-10s %s\n' "${s:-?}" "${f#"$FOX_DIR"/}"
        found=1
    done < <(find "$FOX_DIR/bootable/recovery" "$FOX_DIR/vendor/recovery" -type f -iname '*.png' 2>/dev/null \
             | grep -iE 'splash|logo|banner|fox|orange' | sort)
    [ "$found" = 1 ] || echo "  (none found - is the source synced?)"
    echo
    echo "Pick the file(s) to replace and add lines to branding/images.map, e.g."
    echo "  splash_1080x2340.png | <path from the list above>"
    exit 0
fi

if [ "$MODE" = "--revert" ]; then
    n=0
    while IFS= read -r -d '' b; do mv -f "$b" "${b%.orig}" && n=$((n+1)); done \
        < <(find "$FOX_DIR/bootable/recovery" "$FOX_DIR/vendor/recovery" "$FOX_DIR/device" -name '*.png.orig' -print0 2>/dev/null)
    echo "Restored $n image(s)."
    exit 0
fi

# ---- --apply
[ -f "$MAP" ] || { echo "No $MAP - nothing to apply."; exit 0; }
ok=0; bad=0
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -n "$(echo "$line" | tr -d ' \t\r')" ] || continue
    IFS='|' read -r src dst opt <<<"$line"
    src="$(echo "$src" | xargs)"; dst="$(echo "$dst" | xargs)"; opt="$(echo "${opt:-}" | xargs)"
    S="$BRAND_DIR/$src"; D="$FOX_DIR/$dst"
    case "$dst" in
        bootable/recovery/*|vendor/recovery/*|device/*) ;;
        *) warn "skip '$dst': destination must be under bootable/recovery, vendor/recovery or device"; bad=$((bad+1)); continue ;;
    esac
    case "$dst" in *..*) warn "skip '$dst': '..' not allowed"; bad=$((bad+1)); continue ;; esac
    [ -f "$S" ] || { warn "skip: source not found: branding/$src"; bad=$((bad+1)); continue; }
    [ -f "$D" ] || { warn "skip: destination does not exist in the source tree: $dst"; bad=$((bad+1)); continue; }
    ss="$(png_size "$S")"; ds="$(png_size "$D")"
    [ -f "$D.orig" ] || cp -p "$D" "$D.orig"
    if [ -n "$ds" ] && [ "$ss" != "$ds" ]; then
        if [ "$opt" = "resize" ] && command -v convert >/dev/null; then
            convert "$S" -resize "${ds}!" "$D" || { warn "convert failed for $dst"; bad=$((bad+1)); continue; }
            echo "replaced (resized $ss -> $ds): $dst"; ok=$((ok+1)); continue
        fi
        warn "size mismatch for $dst: yours is $ss, original is $ds (add '| resize' to scale it)"
        bad=$((bad+1)); continue
    fi
    cp -f "$S" "$D" && { echo "replaced ($ss): $dst"; ok=$((ok+1)); }
done < "$MAP"
echo "Branding images: $ok replaced, $bad skipped."
exit 0
