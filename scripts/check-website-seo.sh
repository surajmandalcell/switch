#!/usr/bin/env bash
# Fails when a public HTML page is missing from the sitemap or the sitemap/robots files are wrong.
set -euo pipefail

public="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/packages/website/public"
origin="https://switch.mandalsuraj.com"

xmllint --noout "$public/sitemap.xml"
grep -qx "Sitemap: $origin/sitemap.xml" "$public/robots.txt"

cd "$public"
for page in $(find . -name '*.html' | sed 's#^\./##; s#index\.html$##' | sort); do
  grep -q "<loc>$origin/$page</loc>" sitemap.xml || { echo "missing from sitemap: /$page" >&2; exit 1; }
done
echo "website seo ok"
