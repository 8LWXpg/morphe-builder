#!/usr/bin/env bash
# Download an APK: try archive.org, then apk-fetch (apkcombo -> apkpure -> apkmirror).
# Usage: ./dl-apk.sh <package-id> <archive-url> <output> [version]
#   package-id:  e.g. com.instagram.android
#   archive-url: e.g. https://archive.org/download/jhc-apks/apks/com.instagram.android (empty to skip)
#   output:      exact file path to write the apk to; a split bundle is written to "<output>.apkm" instead
set -euo pipefail

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() { echo >&2 -e "\033[0;31m[-] ${1}\033[0m"; }

pkg=${1:?usage: dl-apk.sh <package-id> <archive-url> <output> [version]}
archive_url=${2-}
output=${3:?usage: dl-apk.sh <package-id> <archive-url> <output> [version]}
version=${4-}

mkdir -p "$(dirname "$output")"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# move whatever the downloader produced into place; split bundles (.apkm/.xapk) go to "$output.apkm"
place() {
	case "$1" in
	*.apkm | *.xapk) mv -f "$1" "${output}.apkm" ;;
	*) mv -f "$1" "$output" ;;
	esac
}

if [ -n "$archive_url" ]; then
	# pick the file matching $version, or the newest listed entry if no version was requested;
	# if a version WAS requested and isn't listed, file stays empty rather than silently
	# substituting the wrong version. A missing/404 archive listing also falls through below.
	listing=$(curl -fsSL "$archive_url" | sed -n 's;^<a href="\([^"]*\)"[^>]*>.*;\1;p') || listing=""
	if [ -n "$version" ]; then
		candidates=$(grep -- "-${version}-" <<<"$listing") || candidates=""
	else
		# newest version = last listed; keep every arch variant of it for the arch pick below
		newest=$(tail -n1 <<<"$listing" | sed -n 's;.*-\([0-9][0-9.]*\)-.*;\1;p') || newest=""
		candidates=$([ -n "$newest" ] && grep -- "-${newest}-" <<<"$listing" || tail -n1 <<<"$listing") || candidates=""
	fi
	# archive.org only carries "-arm64-v8a.<ext>" or "-all.<ext>" builds; take those, skip "-arm-v7a." etc.
	file=$(grep -m1 -- '-arm64-v8a\.' <<<"$candidates") ||
		file=$(grep -m1 -- '-all\.' <<<"$candidates") || file=""
	if [ -n "$file" ] && curl -fsSL -o "$scratch/$file" "${archive_url%/}/$file"; then
		place "$scratch/$file"
		pr "Downloaded '$pkg' via archive.org ($file)"
		exit 0
	fi
	epr "Could not download '$pkg' from archive.org, falling back to apk-fetch"
else
	epr "No archive-url given for '$pkg', skipping archive.org"
fi

if out=$(apk-fetch get "$pkg" ${version:+--version "$version"} --arch arm64-v8a --output "$scratch" --json 2>/dev/null); then
	f=$(jq -r .path <<<"$out") || f=""
	[ -f "$f" ] || f=$(find "$scratch" -maxdepth 1 -type f | head -1)
	if [ -n "$f" ] && [ -f "$f" ]; then
		place "$f"
		pr "Downloaded '$pkg' via apk-fetch (${version:-latest})"
		exit 0
	fi
	epr "Could not download '$pkg' via apk-fetch"
fi
epr "Could not download '$pkg' from any source"
exit 1