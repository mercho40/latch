#!/usr/bin/env python3
"""Fails when the site stops being what it claims to be: one round trip of HTML, no third parties,
an installer identical to the one in Scripts, and a CSP that still matches the inline script."""
import base64, gzip, hashlib, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
site = root / "site"
html = (site / "index.html").read_text()
problems = []

# The server's first flight is about 14 KB. gzip is the pessimistic measure; Brotli is smaller.
first_flight = len(gzip.compress(html.encode(), 9))
if first_flight > 14_000:
    problems.append(f"index.html is {first_flight} bytes gzipped; the budget is 14000")

if (site / "install.sh").read_bytes() != (root / "Scripts" / "install.sh").read_bytes():
    problems.append("site/install.sh differs from Scripts/install.sh; copy it across")

script = re.search(r"<script>(.*?)</script>", html, re.S).group(1)
digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
if f"'sha256-{digest}'" not in (site / "_headers").read_text():
    problems.append(f"_headers does not allow the inline script; its hash is sha256-{digest}")

# Everything the page loads comes from the page's own origin.
for url in re.findall(r'(?:src|srcset|imagesrcset)="([^"]+)"', html):
    for part in url.split(","):
        path = part.strip().split(" ")[0]
        if path.startswith(("http:", "https:", "//")):
            problems.append(f"the page loads {path} from another origin")
        elif not (site / path.lstrip("/")).is_file():
            problems.append(f"the page references {path}, which does not exist")
if re.search(r'<link[^>]+rel="stylesheet"|<script[^>]+src=', html):
    problems.append("the page has an external stylesheet or script; both are inlined on purpose")

heaviest = max((p.stat().st_size for p in site.glob("img/*/*.avif")), default=0)
if first_flight + heaviest > 100_000:
    problems.append(f"HTML plus the largest image is {first_flight + heaviest} bytes; the budget is 100000")

for problem in problems:
    print(f"SITE: {problem}", file=sys.stderr)
print(f"SITE: index.html {first_flight} bytes gzipped; largest image {heaviest} bytes" + ("" if problems else " — PASS"))
sys.exit(1 if problems else 0)
