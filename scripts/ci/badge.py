#!/usr/bin/env python3
# scripts/ci/badge.py <label> <value> <color> — prints a flat shields-style
# SVG badge to stdout. Color is picked by the caller (green >=90, yellow
# >=75, red below); this script only draws. stdlib only, no network.
import sys

COLORS = {"green": "#2ea44f", "yellow": "#dfb317", "red": "#e05d44"}
CHAR_W = 6.5  # rough average glyph width at the font size below


def width(text):
    return round(len(text) * CHAR_W) + 10


def main():
    if len(sys.argv) != 4:
        print("usage: badge.py <label> <value> <color>", file=sys.stderr)
        return 1
    label, value, color = sys.argv[1:4]
    fill = COLORS.get(color, color)
    lw, vw = width(label), width(value)
    total = lw + vw
    print(f"""<svg xmlns="http://www.w3.org/2000/svg" width="{total}" height="20" role="img" aria-label="{label}: {value}">
  <linearGradient id="s" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <clipPath id="r"><rect width="{total}" height="20" rx="3" fill="#fff"/></clipPath>
  <g clip-path="url(#r)">
    <rect width="{lw}" height="20" fill="#555"/>
    <rect x="{lw}" width="{vw}" height="20" fill="{fill}"/>
    <rect width="{total}" height="20" fill="url(#s)"/>
  </g>
  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,sans-serif" font-size="11">
    <text x="{lw / 2}" y="14">{label}</text>
    <text x="{lw + vw / 2}" y="14">{value}</text>
  </g>
</svg>""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
