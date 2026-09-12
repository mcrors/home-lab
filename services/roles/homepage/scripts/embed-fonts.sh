#!/usr/bin/env bash
#
# Regenerate the @font-face block at the bottom of files/custom.css.
#
# Homepage loads exactly one stylesheet, so the font has to travel inside it.
# A <link> to fonts.googleapis.com would put a public third party in the load
# path of an internal dashboard and leak a request every time the page opens,
# so the woff2 is inlined as a data: URI instead.
#
# This script is build-time only. It never runs on a cluster node, which is why
# it lives in scripts/ rather than files/ — everything in files/ is content that
# gets shipped somewhere.
#
# Run it from the repo root after changing the font, the weights, or the subset:
#
#   ./services/roles/homepage/scripts/embed-fonts.sh
#
# It is idempotent: it truncates custom.css at the fence line and rewrites
# everything below, leaving the hand-written CSS above untouched.

set -euo pipefail

FAMILY="IBM+Plex+Mono"
WEIGHTS="300;400;500"
CSS="$(cd "$(dirname "$0")/.." && pwd)/files/custom.css"
FENCE="/* ===== GENERATED BELOW THIS LINE — see scripts/embed-fonts.sh ===== */"

# Google's CSS API serves woff2 only to a browser-shaped User-Agent; with curl's
# default it hands back ttf, which is several times larger for no benefit.
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsS -A "$UA" \
  "https://fonts.googleapis.com/css2?family=${FAMILY}:wght@${WEIGHTS}&display=swap" \
  -o "$tmp/src.css"

# Keep the latin subset only. Google splits each weight into ~5 subsets
# (cyrillic, greek, vietnamese, latin-ext, latin); this dashboard is English and
# the other four would quadruple the file for glyphs nothing renders. The latin
# block is the one whose unicode-range starts at U+0000-00FF.
python3 - "$tmp/src.css" "$FENCE" <<'PY' > "$tmp/fonts.css"
import base64, re, sys, urllib.request

src, fence = open(sys.argv[1]).read(), sys.argv[2]
blocks = re.findall(r"@font-face\s*\{(.*?)\}", src, re.S)

out = [fence, ""]
found = 0
for body in blocks:
    if "U+0000-00FF" not in body:
        continue
    weight = re.search(r"font-weight:\s*(\d+)", body).group(1)
    url = re.search(r"url\((https://[^)]+\.woff2)\)", body).group(1)
    data = urllib.request.urlopen(url, timeout=60).read()
    b64 = base64.b64encode(data).decode()
    out.append(
        "@font-face{font-family:'IBM Plex Mono';font-style:normal;"
        f"font-weight:{weight};font-display:swap;"
        f"src:url(data:font/woff2;base64,{b64}) format('woff2')}}"
    )
    found += 1
    print(f"  weight {weight}: {len(data)} bytes woff2", file=sys.stderr)

if not found:
    sys.exit("no latin subset found — did the Google Fonts CSS format change?")
print("\n".join(out))
PY

# Rewrite everything from the fence down, leaving the hand-written CSS above it.
python3 - "$CSS" "$tmp/fonts.css" "$FENCE" <<'PY'
import sys
css_path, fonts_path, fence = sys.argv[1], sys.argv[2], sys.argv[3]
css = open(css_path).read()
head = css.split(fence)[0].rstrip() + "\n\n"
open(css_path, "w").write(head + open(fonts_path).read())
PY

echo "wrote $CSS ($(wc -c < "$CSS") bytes)"
