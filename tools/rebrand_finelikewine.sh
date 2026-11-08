#!/usr/bin/env bash
#
# Rebrand the on-screen name "OrangeFox" -> "FinELikEWinE" in a synced OrangeFox source tree.
#
# Usage:
#   ./rebrand_finelikewine.sh [FOX_DIR]            # DRY RUN: only lists what would change
#   ./rebrand_finelikewine.sh --apply [FOX_DIR]    # actually edit (keeps a .orig backup per file)
#   ./rebrand_finelikewine.sh --revert [FOX_DIR]   # put the .orig backups back
#
# What it touches : capitalised "OrangeFox" in gui/theme/**/*.xml  (menu text, titles, about page text)
# What it NEVER touches:
#   - lowercase identifiers  (ro.orangefox.*, orangefox paths, /sdcard/Fox ...) - OrangeFox's own
#     scripts and flashable addons look these up by name, renaming them breaks features.
#   - lines that look like credits / licence / project attribution / URLs. OrangeFox is GPL-3.0:
#     keep the attribution, say "based on OrangeFox", and publish your sources if you distribute builds.
#   - images (splash, logo PNGs) - replace those by hand, see the notes printed at the end.
#
# Run it AFTER 'repo sync' and BEFORE building. Re-run after every 'repo sync' (sync restores the files).

MODE=dry
FOX_DIR=""
for a in "$@"; do
    case "$a" in
        --apply)  MODE=apply ;;
        --revert) MODE=revert ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) FOX_DIR="$a" ;;
    esac
done
FOX_DIR="${FOX_DIR:-$HOME/fox_12.1}"
NEW="FinELikEWinE"
THEME_DIR="$FOX_DIR/bootable/recovery/gui/theme"

[ -d "$THEME_DIR" ] || { echo "ERROR: $THEME_DIR not found. Is FOX_DIR right and the source synced?"; exit 1; }

# lines matching this (case-insensitive) are left alone: attribution / legal / links
KEEP='project|copyright|licen[sc]e|gpl|credit|thanks|team|developer|http|www\.|\.org|\.com|\.tech'

mapfile -t FILES < <(grep -rl --include='*.xml' 'OrangeFox' "$THEME_DIR" 2>/dev/null | sort)

if [ "$MODE" = "revert" ]; then
    n=0
    while IFS= read -r -d '' b; do
        mv -f "$b" "${b%.orig}" && n=$((n+1))
    done < <(find "$THEME_DIR" -name '*.xml.orig' -print0)
    echo "Restored $n file(s)."
    exit 0
fi

if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No capitalised 'OrangeFox' found in $THEME_DIR/**/*.xml - nothing to do."
    echo "(The name may live elsewhere in this source version; try: grep -rn 'OrangeFox' $FOX_DIR/bootable/recovery/gui | head)"
    exit 0
fi

total_change=0
total_keep=0
for f in "${FILES[@]}"; do
    change=$(grep -v -iE "$KEEP" "$f" | grep -c 'OrangeFox')
    keep=$(grep -iE "$KEEP" "$f" | grep -c 'OrangeFox')
    total_change=$((total_change + change))
    total_keep=$((total_keep + keep))
    [ "$change" -eq 0 ] && continue
    rel="${f#"$FOX_DIR"/}"
    echo "--- $rel : $change line(s) would change, $keep kept (attribution)"
    if [ "$MODE" = "dry" ]; then
        grep -n -v -iE "$KEEP" "$f" | grep 'OrangeFox' | head -8 | sed 's/^/      /'
    else
        [ -f "$f.orig" ] || cp -p "$f" "$f.orig"
        sed -i -E "/$KEEP/I! s/OrangeFox/$NEW/g" "$f"
        # never leave a broken theme behind
        if ! python3 -c "import sys,xml.dom.minidom as m; m.parse(sys.argv[1])" "$f" 2>/dev/null; then
            echo "      !! $rel is no longer valid XML - rolled back"
            mv -f "$f.orig" "$f"
        fi
    fi
done

echo
echo "Summary: $total_change line(s) to rebrand, $total_keep attribution line(s) deliberately kept."
if [ "$MODE" = "dry" ]; then
    echo "This was a DRY RUN. Review the list above, then run with --apply."
else
    echo "Applied. Backups are *.xml.orig next to each file; undo with --revert."
fi

cat <<EOF

Not handled by this script (do by hand if you want them):
  * Boot splash / logo images : bootable/recovery/gui/theme/common/**  (PNG files, keep same size/format)
  * Output zip prefix "OrangeFox-" : comes from vendor/recovery build scripts. build_finelikewine.sh
    already copies the finished files out as ${NEW}-<device>-<date>.img/.zip, which is usually enough.
  * Version string (FOX_VERSION) : leave as is unless you really want your own versioning.
EOF
