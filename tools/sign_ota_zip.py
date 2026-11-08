#!/usr/bin/env python3
"""
Whole-file signer / verifier for Android recovery packages (sideload + "install from storage").

Format (identical to AOSP SignApk.signWholeFile, checked against the verifier in
bootable/recovery install/verifier.cpp):
  zip bytes (the EOCD comment-length field is excluded from the signed data)
  + 2-byte comment length
  + comment = "signed by ...\\0" + PKCS#7 (DER, detached, NO signed attributes) + 6-byte footer
  footer    = <2B signature_start> 0xFF 0xFF <2B comment_size>   (little endian)

The hash (SHA-1 or SHA-256) MUST match the signature algorithm of the trusted certificate,
because the recovery picks the hash from the certificate. The AOSP test key is sha1WithRSA.

Usage:
  sign_ota_zip.py sign   IN.zip OUT.zip [--cert X509.pem] [--key KEY.pk8|.pem]
  sign_ota_zip.py verify SIGNED.zip      [--cert X509.pem]
Only needs python3 + the openssl command line tool.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEF_CERT = os.path.join(HERE, "..", "keys", "testkey.x509.pem")
DEF_KEY = os.path.join(HERE, "..", "keys", "testkey.pk8")
EOCD_MAGIC = b"PK\x05\x06"
MESSAGE = b"signed by FinELikEWinE"


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, check=True, capture_output=True, **kw)
    except FileNotFoundError:
        die("openssl command not found")
    except subprocess.CalledProcessError as e:
        die("%s failed: %s" % (" ".join(cmd[:3]), e.stderr.decode(errors="replace").strip()))


def cert_hash(cert):
    """Return 'sha1' or 'sha256' exactly like verifier.cpp does, from the cert's signature algorithm."""
    txt = run(["openssl", "x509", "-in", cert, "-noout", "-text"]).stdout.decode()
    for line in txt.splitlines():
        if "Signature Algorithm:" in line:
            alg = line.split(":", 1)[1].strip().lower()
            if alg.startswith(("md5with", "sha1with")):
                return "sha1"
            if alg.startswith("sha256with"):
                return "sha256"
            die("unsupported certificate signature algorithm: " + alg)
    die("could not read the certificate signature algorithm")


def key_to_pem(key, tmpdir):
    with open(key, "rb") as f:
        head = f.read(32)
    if head.startswith(b"-----BEGIN"):
        return key
    out = os.path.join(tmpdir, "key.pem")
    run(["openssl", "pkcs8", "-inform", "DER", "-nocrypt", "-in", key, "-out", out])
    return out


def sign(src, dst, cert, key):
    data = open(src, "rb").read()
    if len(data) < 22 or data[-22:-18] != EOCD_MAGIC or data[-2:] != b"\x00\x00":
        die("input must be an UNSIGNED zip with an empty archive comment")
    h = cert_hash(cert)
    region = data[:-2]  # everything except the comment-length field
    with tempfile.TemporaryDirectory() as td:
        pem = key_to_pem(key, td)
        rf = os.path.join(td, "region.bin")
        with open(rf, "wb") as f:
            f.write(region)
        sig = run(["openssl", "smime", "-sign", "-binary", "-noattr", "-md", h,
                   "-signer", cert, "-inkey", pem, "-in", rf, "-outform", "DER"]).stdout
    for n in range(100):  # avoid "PK\5\6" inside the comment (the verifier rejects that)
        msg = MESSAGE + (b" " * n) + b"\x00"
        total = len(msg) + len(sig) + 6
        footer = struct.pack("<HBBH", len(sig) + 6, 0xFF, 0xFF, total)
        comment = msg + sig + footer
        if EOCD_MAGIC not in comment and total < 0xFFFF:
            break
    else:
        die("could not build a valid comment")
    with open(dst, "wb") as f:
        f.write(region + struct.pack("<H", total) + comment)
    print("signed (%s): %s" % (h, dst))


# ---- minimal DER reader, mirrors read_pkcs7() in verifier.cpp ---------------------------------
def tlv(buf, pos):
    tag = buf[pos]
    pos += 1
    ln = buf[pos]
    pos += 1
    if ln & 0x80:
        n = ln & 0x7F
        ln = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    return tag, pos, pos + ln  # tag, content start, content end


def children(buf, start, end):
    pos = start
    while pos < end:
        tag, cs, ce = tlv(buf, pos)
        yield tag, cs, ce
        pos = ce


def read_pkcs7_signature(der):
    t, cs, ce = tlv(der, 0)
    if t != 0x30:
        raise ValueError("ContentInfo is not a SEQUENCE")
    kids = list(children(der, cs, ce))
    if len(kids) < 2 or kids[1][0] != 0xA0:
        raise ValueError("no [0] content")
    t, cs, ce = tlv(der, kids[1][1])  # SignedData SEQUENCE inside [0]
    if t != 0x30:
        raise ValueError("SignedData is not a SEQUENCE")
    kids = list(children(der, cs, ce))
    rest = [k for k in kids[3:] if k[0] not in (0xA0, 0xA1)]  # skip version/algs/content, certs, crls
    if not rest or rest[0][0] != 0x31:
        raise ValueError("no SignerInfos SET")
    signer = next(children(der, rest[0][1], rest[0][2]))
    if signer[0] != 0x30:
        raise ValueError("SignerInfo is not a SEQUENCE")
    items = list(children(der, signer[1], signer[2]))
    if len(items) < 5 or items[4][0] != 0x04:
        raise ValueError("SignerInfo has authenticated attributes / unexpected layout "
                         "(recovery needs a direct signature)")
    return der[items[4][1]:items[4][2]]


def verify(path, cert):
    data = open(path, "rb").read()
    n = len(data)
    if n < 6:
        die("file too small")
    footer = data[-6:]
    if footer[2] != 0xFF or footer[3] != 0xFF:
        die("footer marker (FF FF) missing - not signed")
    sig_start = footer[0] | footer[1] << 8
    comment_size = footer[4] | footer[5] << 8
    if sig_start > comment_size or sig_start <= 6:
        die("bad signature start")
    eocd_size = comment_size + 22
    if n < eocd_size:
        die("comment larger than file")
    eocd = data[n - eocd_size:]
    if eocd[:4] != EOCD_MAGIC:
        die("signature length doesn't match EOCD marker")
    if EOCD_MAGIC in eocd[4:]:
        die("EOCD marker occurs after start of EOCD")
    signed_len = n - eocd_size + 22 - 2
    h = cert_hash(cert)
    digest = hashlib.new(h, data[:signed_len]).digest()
    sig_der = data[n - sig_start: n - 6]
    try:
        raw_sig = read_pkcs7_signature(sig_der)
    except (ValueError, IndexError) as e:
        die("could not read signature block: %s" % e)
    with tempfile.TemporaryDirectory() as td:
        pub = os.path.join(td, "pub.pem")
        dg = os.path.join(td, "d.bin")
        sg = os.path.join(td, "s.bin")
        with open(pub, "wb") as f:
            f.write(run(["openssl", "x509", "-in", cert, "-pubkey", "-noout"]).stdout)
        with open(dg, "wb") as f:
            f.write(digest)
        with open(sg, "wb") as f:
            f.write(raw_sig)
        r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub, "-in", dg,
                            "-sigfile", sg, "-pkeyopt", "digest:" + h], capture_output=True)
    if r.returncode != 0:
        die("signature does NOT verify against " + cert)
    print("OK: whole-file signature verified (%s, RSA) against %s" % (h, os.path.basename(cert)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sign")
    s.add_argument("src")
    s.add_argument("dst")
    s.add_argument("--cert", default=DEF_CERT)
    s.add_argument("--key", default=DEF_KEY)
    v = sub.add_parser("verify")
    v.add_argument("zip")
    v.add_argument("--cert", default=DEF_CERT)
    a = ap.parse_args()
    if a.cmd == "sign":
        sign(a.src, a.dst, a.cert, a.key)
    else:
        verify(a.zip, a.cert)


if __name__ == "__main__":
    main()
