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
err=$(mktemp)
trap 'rm -rf "$scratch" "$err"' EXIT

# move whatever the downloader produced into place; split bundles (.apkm/.xapk) go to "$output.apkm".
# the version actually downloaded is left in "$output.ver" for the caller.
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
	newest=""
	listing=$(curl -fsSL "$archive_url" | sed -n 's;^<a href="\([^"]*\)"[^>]*>.*;\1;p') || listing=""
	if [ -n "$version" ]; then
		candidates=$(grep -- "-${version}-" <<<"$listing") || candidates=""
	else
		# newest version = last listed; keep every arch variant of it for the arch pick below
		newest=$(tail -n1 <<<"$listing" | sed -n 's;.*-\([0-9][0-9.]*\)-.*;\1;p') || newest=""
		candidates=$([ -n "$newest" ] && grep -- "-${newest}-" <<<"$listing" || tail -n1 <<<"$listing") || candidates=""
	fi
	# -arm64-v8a is what works; -all is the fallback. skip -arm-v7a and friends.
	file=$(grep -m1 -e '-arm64-v8a\.' -e '-all\.' <<<"$candidates") || file=""
	if [ -n "$file" ] && curl -fsSL -o "$scratch/$file" "${archive_url%/}/$file"; then
		place "$scratch/$file"
		printf '%s' "${version:-$newest}" >"$output.ver"
		pr "Downloaded '$pkg' via archive.org ($file)"
		exit 0
	fi
	epr "Could not download '$pkg' from archive.org, falling back to apk-fetch"
else
	epr "No archive-url given for '$pkg', skipping archive.org"
fi

if out=$(apk-fetch get "$pkg" ${version:+--version "$version"} --arch arm64-v8a --output "$scratch" --json 2>"$err"); then
	f=$(jq -r .path <<<"$out") || f=""
	if [ -f "$f" ]; then
		place "$f"
		# the version we ended up with, so the caller can name its outputs
		printf '%s' "$(jq -r .version <<<"$out")" >"$output.ver"
		pr "Downloaded '$pkg' via apk-fetch (${version:-latest})"
		exit 0
	fi
fi
# apk-fetch reports why each provider failed on stderr; don't throw that away
if [ -s "$err" ]; then tr '\r' '\n' <"$err" >&2; fi
epr "Could not download '$pkg' from any source"
exit 1