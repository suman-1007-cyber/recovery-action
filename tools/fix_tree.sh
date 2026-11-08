#!/usr/bin/env bash
#
# Repair two classic problems that happen when a device tree is committed from Windows:
#   1. symlinks flattened into tiny text files  (e.g. gatekeeper.default.so containing "libSoftGatekeeper.so")
#   2. lost executable bits on binaries and scripts inside recovery/root
# Safe to run on every build: it only touches files that clearly match, and prints what it changed.
#
#   bash tools/fix_tree.sh <device tree dir>

TREE="${1:-}"
[ -d "$TREE/recovery/root" ] || { echo "fix_tree: no recovery/root in '$TREE' - nothing to do."; exit 0; }
ROOT="$TREE/recovery/root"
links=0; modes=0

# ---- 1. flattened symlinks: small regular file whose whole content is the name of a sibling file
while IFS= read -r -d '' f; do
    size=$(stat -c %s "$f")
    [ "$size" -gt 0 ] && [ "$size" -lt 128 ] || continue
    target="$(tr -d '\r\n' < "$f")"
    [[ "$target" =~ ^[A-Za-z0-9._+-]+$ ]] || continue
    dir="$(dirname "$f")"
    [ -f "$dir/$target" ] && [ ! -L "$dir/$target" ] || continue
    [ "$(basename "$f")" != "$target" ] || continue
    # only convert library-like files; a tiny config file that happens to name a sibling must stay a file
    case "$f" in *.so|*.so.*) ;; *) continue ;; esac
    rm -f "$f" && ln -s "$target" "$f"
    echo "fix_tree: symlink restored: ${f#"$TREE"/} -> $target"
    links=$((links+1))
done < <(find "$ROOT" -type f -print0)

# ---- 2. executable bits: ELF files in bin dirs / hw_encrypt, and anything starting with #!
while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue
    [ -x "$f" ] && continue
    magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"   # hex, so binaries are safe
    want=0
    if [ "${magic:0:4}" = "2321" ]; then want=1; fi                       # "#!"
    if [ "$magic" = "7f454c46" ]; then                                    # ELF
        case "$f" in */bin/*|*/hw_encrypt/*|*/xbin/*) want=1 ;; esac
    fi
    if [ "$want" = "1" ]; then
        chmod 755 "$f"
        echo "fix_tree: made executable: ${f#"$TREE"/}"
        modes=$((modes+1))
    fi
done < <(find "$ROOT" -type f -print0)

echo "fix_tree: $links symlink(s) restored, $modes file(s) made executable."
exit 0
