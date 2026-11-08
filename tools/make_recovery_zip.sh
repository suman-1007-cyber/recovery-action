#!/usr/bin/env bash
#
# Build a FinELikEWinE recovery zip that installs from
#   * AOSP-style recoveries: "adb sideload" and "install from storage"
#     (zip is whole-file signed with the public AOSP test key)
#   * TWRP / OrangeFox style recoveries (they run the same update-binary)
#
# Usage:
#   bash tools/make_recovery_zip.sh -i recovery.img [-D "lancelot galahad shiva"] [-o out.zip]
#   bash tools/make_recovery_zip.sh -i recovery.img -T device/xiaomi/lancelot   # read device list from the tree
#
#   -i FILE   recovery.img from the build                                        [required]
#   -D LIST   space separated device codenames the zip may be flashed on
#   -T DIR    device tree dir: use FOX_TARGET_DEVICES from its vendorsetup.sh
#   -o FILE   output zip   (default: ./FinELikEWinE-<first device>-<date>-sideload.zip)
#   -N NAME   brand name   (default: FinELikEWinE)
#   -c FILE   signing certificate (default: keys/testkey.x509.pem)
#   -k FILE   signing key         (default: keys/testkey.pk8)
#   -u        do NOT sign (unsigned zip; only TWRP/OrangeFox style recoveries will take it)
#
# Needs: bash, zip, python3, openssl, sha256sum

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG=""; DEVICES=""; TREE=""; OUT=""; NAME="FinELikEWinE"
CERT="$TOOLS/../keys/testkey.x509.pem"; KEY="$TOOLS/../keys/testkey.pk8"; SIGN=1

die() { echo "ERROR: $*" >&2; exit 1; }

while getopts "i:D:T:o:N:c:k:uh" opt; do
    case "$opt" in
        i) IMG="$OPTARG" ;;  D) DEVICES="$OPTARG" ;;  T) TREE="$OPTARG" ;;
        o) OUT="$OPTARG" ;;  N) NAME="$OPTARG" ;;
        c) CERT="$OPTARG" ;; k) KEY="$OPTARG" ;;  u) SIGN=0 ;;
        *) sed -n '2,22p' "$0"; exit 2 ;;
    esac
done
[ -n "$IMG" ] || { sed -n '2,22p' "$0"; exit 2; }

for t in zip python3 openssl sha256sum; do command -v "$t" >/dev/null || die "$t is not installed"; done
[ -f "$IMG" ] || die "image not found: $IMG"
[ -f "$TOOLS/update-binary.template" ] || die "update-binary.template missing next to this script"

if [ -z "$DEVICES" ] && [ -n "$TREE" ]; then
    DEVICES="$(grep -o 'FOX_TARGET_DEVICES="[^"]*"' "$TREE/vendorsetup.sh" 2>/dev/null | head -1 | sed 's/.*="//; s/"$//; s/,/ /g')"
fi
[ -n "$DEVICES" ] || die "no device list: pass -D \"lancelot galahad shiva\" or -T <device tree dir>"
case "$DEVICES" in *[!a-zA-Z0-9_\ ]*) die "device list may only contain letters, digits, _ and spaces" ;; esac
FIRST="${DEVICES%% *}"

# ---- image sanity
[ "$(head -c 8 "$IMG")" = "ANDROID!" ] || die "$IMG does not start with the Android boot image magic"
SIZE="$(stat -c %s "$IMG")"
SHA="$(sha256sum "$IMG" | cut -d' ' -f1)"
echo "Image : $IMG ($SIZE bytes)"
echo "SHA256: $SHA"
echo "Devices allowed: $DEVICES"

[ -n "$OUT" ] || OUT="./${NAME}-${FIRST}-$(date +%Y%m%d)-sideload.zip"
OUT="$(readlink -f "$OUT")"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE/META-INF/com/google/android"
UNSIGNED="$WORK/unsigned.zip"

# ---- 1) recovery.img FIRST and STORED (not compressed): the installer can then cut it out by byte
#         offset if the recovery has no unzip tool. -X drops extra fields so the offset is 30 + len(name).
cp "$IMG" "$STAGE/recovery.img"
( cd "$STAGE" && zip -q -X -0 "$UNSIGNED" recovery.img ) || die "zip failed"
OFFSET="$(python3 - "$UNSIGNED" <<'EOF'
import struct, sys
d = open(sys.argv[1], 'rb').read(64)
sig, ver, flag, method, t, dt, crc, csz, usz, nlen, elen = struct.unpack('<IHHHHHIIIHH', d[:30])
assert sig == 0x04034b50, 'not a local file header'
assert method == 0, 'recovery.img is not stored uncompressed'
assert elen == 0, 'unexpected extra field (%d bytes)' % elen
assert d[30:30 + nlen] == b'recovery.img'
print(30 + nlen)
EOF
)" || die "could not determine the stored offset of recovery.img"
echo "Offset: $OFFSET"

# ---- 2) installer script (values baked in)
sed -e "s|@NAME@|$NAME|g" -e "s|@DATE@|$(date +%F)|g" -e "s|@SIZE@|$SIZE|g" \
    -e "s|@SHA256@|$SHA|g" -e "s|@OFFSET@|$OFFSET|g" -e "s|@DEVICES@|$DEVICES|g" \
    "$TOOLS/update-binary.template" > "$STAGE/META-INF/com/google/android/update-binary"
chmod 755 "$STAGE/META-INF/com/google/android/update-binary"
printf '# %s: the installer is the update-binary script next to this file.\n' "$NAME" \
    > "$STAGE/META-INF/com/google/android/updater-script"

cat > "$STAGE/INSTALL" <<EOF
$NAME recovery  -  built $(date +%F)
Devices: $DEVICES

Flash from a recovery (this replaces the recovery partition, then reboot to recovery):
  * AOSP / LineageOS style recovery:  Apply update > Apply from ADB, then on the PC:
        adb sideload $(basename "$OUT")
    A recovery that does not trust the AOSP test key may ask "install anyway?" - choose yes.
  * TWRP / OrangeFox style recovery: Install > pick this zip.
  * Stock Xiaomi/MIUI recovery only accepts Xiaomi-signed zips and will refuse this one.
    Use fastboot instead:  fastboot flash recovery recovery.img  (unzip it first).

Image SHA-256: $SHA
EOF

# ---- 3) add the rest (compressed), keep recovery.img first
( cd "$STAGE" && zip -q -X -9 -r "$UNSIGNED" META-INF INSTALL ) || die "zip failed"

# ---- 4) self-check the byte-offset fallback BEFORE signing
GOT="$(tail -c +$((OFFSET + 1)) "$UNSIGNED" | head -c "$SIZE" | sha256sum | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || die "byte-offset extraction self-test failed"
echo "Byte-offset fallback self-test: ok"

# ---- 5) sign + verify
rm -f "$OUT"
if [ "$SIGN" = "1" ]; then
    python3 "$TOOLS/sign_ota_zip.py" sign "$UNSIGNED" "$OUT" --cert "$CERT" --key "$KEY" || die "signing failed"
    python3 "$TOOLS/sign_ota_zip.py" verify "$OUT" --cert "$CERT" || die "signature self-check failed"
else
    cp "$UNSIGNED" "$OUT"; echo "NOT signed (-u)."
fi
unzip -tq "$OUT" >/dev/null || die "final zip failed its integrity test"
GOT2="$(tail -c +$((OFFSET + 1)) "$OUT" | head -c "$SIZE" | sha256sum | cut -d' ' -f1)"
[ "$GOT2" = "$SHA" ] || die "offset moved after signing (should be impossible)"

echo
echo "Created: $OUT"
unzip -Z1 "$OUT" | sed 's/^/  /'
sha256sum "$OUT"
