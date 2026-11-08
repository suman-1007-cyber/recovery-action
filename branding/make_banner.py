#!/usr/bin/env python3
"""
Regenerate the recovery branding: logo.svg / banner.svg / splash.svg (+ PNG exports).

Make it your own: edit the CONFIG block below (name, colours, tagline, sizes), then run

    pip install fonttools cairosvg
    python3 make_banner.py                       # auto-finds the Inter font
    python3 make_banner.py --font C:\\Windows\\Fonts\\arialbd.ttf   # or give any bold .ttf/.otf

All lettering is converted to outlines, so the SVG/PNG look the same on every machine
(no font needed to VIEW them, only to regenerate them). PNG export needs cairosvg;
without it you still get the SVGs (open them in Inkscape / a browser and export).
"""
import argparse
import glob
import os
import sys

# ----------------------------------------------------------------------------- CONFIG
CONFIG = {
    # wordmark pieces: (text, colour). Change the names / accent colour freely.
    "parts": [("Fin", "#f6ede3"), ("E", "#ff4d6d"), ("Lik", "#f6ede3"),
              ("E", "#ff4d6d"), ("Win", "#f6ede3"), ("E", "#ff4d6d")],
    "subtitle": "RECOVERY",
    "tagline": "smooth. stable. aged to perfection.",
    "gold": "#c9a46a",
    "cream": "#f6ede3",
    "bg_stops": ("#2a0916", "#14060c", "#0a0306"),   # background gradient
    "wine_stops": ("#e11d48", "#7a0a2b"),            # liquid in the glass
    "glow": "#e11d48",
    # output sizes
    "splash_size": (1080, 2340),    # phone boot splash (Redmi 9 / Note 9 screen)
    "banner_size": (1600, 400),
    "logo_size": 512,
}
# ---------------------------------------------------------------------------------------

HERE = os.path.dirname(os.path.abspath(__file__))


def find_font(explicit):
    if explicit:
        return explicit
    for pat in ("/usr/share/fonts/**/Inter-ExtraBold.otf", "/usr/share/fonts/**/Inter*Bold*.ttf",
                "/usr/share/fonts/**/DejaVuSans-Bold.ttf", "/usr/share/fonts/**/LiberationSans-Bold.ttf",
                "C:/Windows/Fonts/arialbd.ttf", "/Library/Fonts/Arial Bold.ttf"):
        hits = sorted(glob.glob(pat, recursive=True))
        if hits:
            return hits[0]
    sys.exit("No bold font found. Pass one with --font /path/to/Font-Bold.ttf")


class Typeface:
    def __init__(self, path):
        from fontTools.ttLib import TTFont
        self.font = TTFont(path, fontNumber=0)
        self.gs = self.font.getGlyphSet()
        self.cmap = self.font.getBestCmap()
        self.upm = self.font["head"].unitsPerEm
        self.hmtx = self.font["hmtx"]

    def width(self, text, size, spacing=0.0):
        s = size / self.upm
        total = 0.0
        for ch in text:
            g = self.cmap.get(ord(ch))
            total += (self.hmtx[g][0] * s if g else size * 0.3) + spacing
        return total - spacing if text else 0.0

    def path(self, text, size, x, y, spacing=0.0):
        """SVG path data for `text` with its baseline at y, starting at x. Returns (d, end_x)."""
        from fontTools.pens.svgPathPen import SVGPathPen
        from fontTools.pens.transformPen import TransformPen
        s = size / self.upm
        pen = SVGPathPen(self.gs, ntos=lambda v: ("%.2f" % v).rstrip("0").rstrip("."))
        cx = x
        for ch in text:
            g = self.cmap.get(ord(ch))
            if g:
                self.gs[g].draw(TransformPen(pen, (s, 0, 0, -s, cx, y)))
                cx += self.hmtx[g][0] * s + spacing
            else:
                cx += size * 0.3 + spacing
        return pen.getCommands(), cx - spacing


def wordmark(tf, size, x, y, anchor="start", spacing=-2.0):
    total = sum(tf.width(t, size, spacing) + spacing for t, _ in CONFIG["parts"]) - spacing
    cx = x - total / 2 if anchor == "middle" else x
    out = []
    for text, colour in CONFIG["parts"]:
        d, cx = tf.path(text, size, cx, y, spacing)
        cx += spacing
        out.append('<path d="%s" fill="%s"/>' % (d, colour))
    return "\n".join(out)


def label(tf, text, size, x, y, fill, spacing=0.0, anchor="start", opacity=1.0):
    w = tf.width(text, size, spacing)
    x0 = x - w / 2 if anchor == "middle" else x
    d, _ = tf.path(text, size, x0, y, spacing)
    return '<path d="%s" fill="%s" fill-opacity="%s"/>' % (d, fill, opacity)


def defs():
    b0, b1, b2 = CONFIG["bg_stops"]
    w0, w1 = CONFIG["wine_stops"]
    cream = CONFIG["cream"]
    return f'''<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{b0}"/><stop offset=".55" stop-color="{b1}"/><stop offset="1" stop-color="{b2}"/></linearGradient>
  <linearGradient id="wine" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{w0}"/><stop offset="1" stop-color="{w1}"/></linearGradient>
  <radialGradient id="glow" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="{CONFIG['glow']}" stop-opacity=".35"/><stop offset="1" stop-color="{CONFIG['glow']}" stop-opacity="0"/></radialGradient>
  <clipPath id="bowl"><path d="M-70 0C-80 72-42 132 0 132C42 132 80 72 70 0Z"/></clipPath>
  <g id="glass">
    <path d="M-70 0C-80 72-42 132 0 132C42 132 80 72 70 0Z" fill="#ffffff" fill-opacity=".06"/>
    <g clip-path="url(#bowl)"><rect x="-90" y="46" width="180" height="100" fill="url(#wine)"/>
      <ellipse cx="0" cy="46" rx="80" ry="9" fill="#ff6b8a" fill-opacity=".55"/></g>
    <path d="M-70 0C-80 72-42 132 0 132C42 132 80 72 70 0" fill="none" stroke="{cream}" stroke-width="5" stroke-linecap="round"/>
    <path d="M-62 14C-66 62-44 100-18 116" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="4" stroke-linecap="round"/>
    <rect x="-4.5" y="130" width="9" height="104" rx="3" fill="{cream}"/>
    <path d="M-52 242C-30 226 30 226 52 242C30 252-30 252-52 242Z" fill="{cream}"/>
  </g>
</defs>'''


def svg(w, h, body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
            f'viewBox="0 0 {w} {h}" width="{w}" height="{h}">\n{defs()}\n{body}\n</svg>\n')


def build(font_path, outdir):
    tf = Typeface(font_path)
    gold, cream = CONFIG["gold"], CONFIG["cream"]
    files = {}

    n = CONFIG["logo_size"]
    k = n / 512.0
    files["logo"] = (n, n, svg(n, n, f'''<g transform="scale({k})">
<circle cx="256" cy="256" r="240" fill="url(#bg)" stroke="{gold}" stroke-width="6"/>
<circle cx="256" cy="230" r="170" fill="url(#glow)"/>
<use href="#glass" xlink:href="#glass" transform="translate(256 122) scale(1.15)"/></g>'''))

    w, h = CONFIG["banner_size"]
    sx = h / 400.0
    files["banner"] = (w, h, svg(w, h, f'''<rect width="{w}" height="{h}" fill="url(#bg)"/>
<g transform="scale({sx})">
<circle cx="250" cy="200" r="230" fill="url(#glow)"/>
<use href="#glass" xlink:href="#glass" transform="translate(250 62) scale(1.05)"/>
<rect x="470" y="60" width="4" height="280" rx="2" fill="{gold}" fill-opacity=".7"/>
{wordmark(tf, 132, 520, 215)}
{label(tf, CONFIG["subtitle"], 46, 526, 282, gold, spacing=14)}
{label(tf, CONFIG["tagline"], 26, 526, 332, cream, spacing=1, opacity=.6)}
</g>'''))

    w, h = CONFIG["splash_size"]
    cx = w / 2
    files["splash"] = (w, h, svg(w, h, f'''<rect width="{w}" height="{h}" fill="url(#bg)"/>
<circle cx="{cx}" cy="{h*0.385:.0f}" r="{w*0.48:.0f}" fill="url(#glow)"/>
<use href="#glass" xlink:href="#glass" transform="translate({cx} {h*0.24:.0f}) scale({w/470:.2f})"/>
{wordmark(tf, w*0.109, cx, h*0.641, anchor="middle")}
<rect x="{cx-100}" y="{h*0.660:.0f}" width="200" height="4" rx="2" fill="{gold}" fill-opacity=".8"/>
{label(tf, CONFIG["subtitle"], w*0.046, cx, h*0.701, gold, spacing=16, anchor="middle")}
{label(tf, CONFIG["tagline"], w*0.028, cx, h*0.735, cream, spacing=1, anchor="middle", opacity=.6)}'''))

    os.makedirs(outdir, exist_ok=True)
    try:
        import cairosvg
    except ImportError:
        cairosvg = None
        print("cairosvg not installed: writing SVGs only (pip install cairosvg for PNGs)")
    names = {"logo": "logo_%d.png" % CONFIG["logo_size"],
             "banner": "banner_%dx%d.png" % CONFIG["banner_size"],
             "splash": "splash_%dx%d.png" % CONFIG["splash_size"]}
    for key, (fw, fh, text) in files.items():
        p = os.path.join(outdir, key + ".svg")
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote", p)
        if cairosvg:
            q = os.path.join(outdir, names[key])
            cairosvg.svg2png(bytestring=text.encode("utf-8"), write_to=q, output_width=fw, output_height=fh)
            print("wrote", q)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--font", help="path to a bold .ttf/.otf (default: auto-detect Inter/DejaVu/Arial)")
    ap.add_argument("--out", default=HERE, help="output folder (default: next to this script)")
    a = ap.parse_args()
    build(find_font(a.font), a.out)
