# FinELikEWinE recovery - GitHub build kit

Builds your OrangeFox-based recovery on GitHub's servers and produces:

| file | use |
|---|---|
| `FinELikEWinE-<device>-<date>.img` | flash with fastboot |
| `FinELikEWinE-<device>-<date>-sideload.zip` | flash / `adb sideload` from an AOSP-style recovery (signed) |
| `FinELikEWinE-<device>-<date>-fox-installer.zip` | OrangeFox's own installer zip (for TWRP/OrangeFox style recoveries) |
| `SHA256SUMS.txt` | checksums |

## 1. Put the kit in your repo (once)

This kit is meant for a separate "builder" repo (like `recovery-action`). The device tree is downloaded at
build time from the `tree_url` you give the workflow (default: the lancelot tree), so the builder repo holds only
the kit: `.github/`, `tools/`, `keys/`, `branding/`, `.gitattributes`, this README.

Easiest on Windows (no git needed): unzip the kit, open your repo on github.com -> **Add file -> Upload files**,
drag the CONTENTS of the unzipped folder in (including the `.github` folder), then **Commit changes** to `main`.

Or with git:

    git clone https://github.com/<you>/recovery-action
    cd recovery-action          # copy the unzipped kit contents in here
    git add .
    git commit -m "Add FinELikEWinE build"
    git push

The workflow file must end up at exactly `.github/workflows/build-finelikewine.yml` on the `main` branch,
otherwise the Actions tab will not show it.

(You can also drop the kit into a device-tree repo itself and run with `tree_url` EMPTY.)

## 2. Build

GitHub -> your repo -> **Actions** -> "Build FinELikEWinE recovery" -> **Run workflow**.
Keep the defaults (`device = lancelot`, tree = the lancelot repo) and press the green button.
Expect roughly 1.5-3 hours. When it is green, open the run and download the artifact at the bottom.
If it fails, download the `build-log-...` artifact: the first line containing `error:` is the real cause.

**merlin later:** put the merlin tree (copy of lancelot's, renamed + its own kernel/dtb) in its own repo and run
this same workflow with `device = merlin` and `tree_url = https://github.com/<you>/<merlin-tree-repo>`.

## 3. Your own banner / splash

`branding/` holds `splash_1080x2340.png` (phone boot splash), `banner_1600x400.png` (README/GitHub banner),
`logo_512.png`, plus the SVG sources. To make your own:

* edit the CONFIG block at the top of `branding/make_banner.py` (name, colours, tagline) and run
  `pip install fonttools cairosvg && python3 branding/make_banner.py`, or
* open the `.svg` files in Inkscape / Figma / a browser and export PNGs yourself
  (keep the pixel sizes, or the replacement is refused unless you add `| resize`).

To make the recovery actually USE an image: run the workflow once, open the step
**"Inspect branding assets"** in the log (it lists every candidate image in the OrangeFox source with its size),
then add a line to `branding/images.map`:

    splash_1080x2340.png | <path copied from that list>

The tool only replaces files that already exist, keeps a `.orig` backup, and warns instead of failing.
The on-screen text "OrangeFox" is rewritten to "FinELikEWinE" by the `rebrand` option (credit/licence lines are kept).

## 4. Installing the result

Fastboot (always works, bootloader unlocked; back up your current recovery first):

    fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
    fastboot flash recovery FinELikEWinE-lancelot-<date>.img
    fastboot reboot recovery

From a recovery that is already installed: Apply update -> Apply from ADB, then

    adb sideload FinELikEWinE-lancelot-<date>-sideload.zip

What the sideload zip does: checks the device codename, checks the image checksum and the partition size,
writes ONLY the `recovery` partition, reads it back and verifies. Any failure stops before or reports it clearly.

## What works where (and what cannot)

* The zip is whole-file signed with the public **AOSP test key** (SHA-1 RSA, the format AOSP recovery verifies).
  AOSP-built recoveries trust it. LineageOS-style recoveries do not carry that key but ask
  "install anyway?" for untrusted zips - say yes. TWRP/OrangeFox just install it.
* **Stock Xiaomi/MIUI recovery only accepts Xiaomi-signed zips.** No third-party zip can pass it, so use fastboot there.
* Needs `/system/bin/sh` in the recovery (every Android 10+ recovery has it - lancelot/merlin are Android 10+).

## Notes

* OrangeFox is GPL-3.0: keep its credits, and publish your sources if you distribute builds.
* `keys/` are the public AOSP test keys (Apache-2.0), not secrets. To sign with your own key:
  `python3 tools/sign_ota_zip.py sign in.zip out.zip --cert my.x509.pem --key my.pk8` (the hash must match the cert).
