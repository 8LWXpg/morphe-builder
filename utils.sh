#!/usr/bin/env bash

TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"

toml_prep() {
	[ -f "$1" ] || return 1
	__TOML__=$(tq --output json --file "$1" .)
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { printf "\033[0;32m[+] %s\033[0m\n" "$1"; }
epr() {
	printf >&2 "\033[0;31m[-] %s\033[0m\n" "$1"
	if [ "${GITHUB_REPOSITORY-}" ]; then printf >&2 "::error::utils.sh [-] %s\n" "$1"; fi
}

_clean_tmp() {
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*tmp_* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	kill -9 -- -$$ 2>/dev/null
	exit 1
}

get_prebuilts() {
	local cli_src=MorpheApp/morphe-cli cli_ver=$1 patches_src=$2 patches_ver=$3
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "Patches $patches_src $patches_ver" "CLI $cli_src $cli_ver"; do
		set -- $src_ver
		local tag=$1 src=$2 ver=${3-}

		local dir=${src%/*}
		dir=${TEMP_DIR}/${dir,,}-rv
		[ -d "$dir" ] || mkdir "$dir"

		if [ "$ver" = "dev" ]; then
			ver=$(gh release list --repo "$src" --json tagName --jq '.[].tagName' | get_highest_ver) || return 1
			# an empty result would leave tag_arg empty, and gh reads that as "latest"
			[ -n "$ver" ] || { epr "No releases found in '$src'"; return 1; }
		fi

		local file name tag_arg v_pat
		# "latest" is gh's default when the tag argument is empty
		tag_arg=; [ "$ver" != latest ] && tag_arg=$ver
		v_pat='*'
		[ "$ver" != latest ] && v_pat=${ver#v}
		# a cached name can match cli-* or desktop-*, and a repeated -G is ignored by compgen
		if [ "$tag" = "CLI" ]; then
			file=$({ compgen -G "$dir/*cli-${v_pat}*.jar"; compgen -G "$dir/*desktop-${v_pat}*.jar"; })
		else
			file=$(compgen -G "$dir/*patches-${v_pat}.*")
		fi
		# "dev" must match the file name only; a dir like "somedev-rv" is a legit cache.
		# skip the check when a dev tag was asked for, or "dev" builds could never be cached.
		if [ "${v_pat}" = "${v_pat/dev/}" ]; then
			file=$(grep -vE "/tmp\.|\.lock$" <<<"$file" |
				while IFS= read -r f; do case ${f##*/} in *dev*) ;; *) echo "$f";; esac; done | head -1)
		else
			file=$(grep -vE "/tmp\.|\.lock$" <<<"$file" | head -1)
		fi
		file=${file:-}
		# a cached entry that isn't a valid zip is a truncated or HTML-error download: delete it
		# so the [ -z "$file" ] branch below re-fetches instead of poisoning the patcher later
		[ -n "$file" ] && ! unzip -tqq "$file" >/dev/null 2>&1 && { rm -f "$file"; file=""; }

		if [ -z "$file" ]; then
			local info tag_name
			# the first asset that isn't a signature/manifest is the one we want
			info=$(gh release view "$tag_arg" --repo "$src" --json tagName,assets \
				--jq '[.tagName, ([.assets[] | select(.name | test("[.](asc|json)$") | not)][0].name // empty)] | @tsv') || return 1
			IFS=$'\t' read -r tag_name name <<<"$info"
			[ -n "$name" ] || {
				epr "No asset was found"
				return 1
			}
			file="${dir}/${name}"
			# stdout carries the "patch_jar cli_jar" pair, so progress goes to stderr
			{ pr "Getting '$file' from '$src/$tag_name'"; gh release download "$tag_arg" --repo "$src" --pattern "$name" --dir "$dir"; } >&2 || return 1
			# gh writes straight to the target, so the validity check has to come after
			unzip -tqq "$file" >/dev/null 2>&1 || { rm -f "$file"; epr "Corrupt download: $name"; return 1; }
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
			if [ "$tag" = "Patches" ]; then
				echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"
			fi
		fi
		echo -n "$file "
	done
	echo
}

log() { printf "%s  \n" "$1" >>"build.md"; }
get_highest_ver() {
	local vers
	vers=$(tee)
	# a non-semver first line is taken as-is
	if [[ $(head -1 <<<"$vers") =~ ^v?[0-9]+(\.[0-9]+)*(-.*)?$ ]]; then
		sort -s -t- -k1,1Vr <<<"$vers" | head -1
	else head -1 <<<"$vers"; fi
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 is_experimental=$4
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			# the cli indents 'Compatible versions:' under 'Compatible packages:' and follows it
			# with a 'Version codes:' block; take the indented lines up to either
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | awk '/Compatible versions:/{f=1;next} f&&/Version codes:/{exit} f&&!NF{exit} f{sub(/^[[:space:]]+/,"");print}')
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(cli "$cli_jar" list-versions --patches="$patches_jar" -f "$pkg_name" ${is_experimental:+-x}) || return 1
	# newer cli annotates versions with ' [versionCodes: ARM64_V8A=...]'; strip it
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d; s/ \[versionCodes:[^]]*\]//' | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	local pcount
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		if grep -Fq "$pkg_name" <<<"$list_patches"; then
			return
		else
			abort "No patches found for '$pkg_name' in patches '$patches_jar'"
		fi
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

cli() {
	local jar=$1 sub=$2 op
	shift 2
	if op=$(java -jar "$jar" "$sub" "$@" 2>&1); then
		echo "$op"
		return
	fi
	epr "Could not run '$sub': '$op'"
	return 1
}

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local tmp_files
	tmp_files="$(pwd)/$(mktemp -d -p "$TEMP_DIR")"

	# --striplibs keeps only arm64-v8a; the patcher strips the rest while merging
	local cmd="java -jar '$cli_jar' patch '$stock_input' -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc \
--striplibs=arm64-v8a -t '$tmp_files' $patcher_args"

	pr "$cmd"
	local ok=1
	if eval "$cmd"; then [ -f "$patched_apk" ] || ok=; else ok=; fi
	# clean up on every exit, not just the end of the build where _clean_tmp runs
	rm -rf "$tmp_files" || :
	[ "$ok" = 1 ] || { rm -f "$patched_apk" 2>/dev/null || :; return 1; }
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -qF "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version=""
	local version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local pkg_name=${args[package_id]}
	local archive_url=${args[archive_dlurl]:-}
	pr "Package name of '${table}' is '$pkg_name'"

	local is_experimental="false"
	if [ "$version_mode" = "experimental" ]; then is_experimental="true"; fi
	local list_patches
	list_patches=$(cli "$cli_jar" list-patches --patches="$patches_jar" -f "$pkg_name" -v -p) || return 1
	local unknown_ver=false
	if [ "$version_mode" = auto ] || [ "$version_mode" = experimental ]; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" "${args[included_patches]}" "$is_experimental"); then
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return
		elif [ -z "$version" ]; then unknown_ver=true; fi
	elif [ "$version_mode" = "latest" ]; then
		unknown_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi

	local version_f=${version// /}
	version_f=${version_f#v}
	# no version pinned: the provider resolves its own latest and reports it back in
	# "$stock_apk.ver". its name can't be predicted, so don't consult the cache.
	if [ "$unknown_ver" = true ]; then version_f=latest; fi
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-arm64-v8a.apk"
	local abi=arm64-v8a
	# a cached universal build already contains every abi, so take it over re-downloading.
	# skipped when the version is unknown: "latest" is not a real version, so a cached
	# latest-all.apk is by definition the wrong content and would also mislabel abi=all
	if [ "$unknown_ver" != true ] && [ ! -f "$stock_apk" ] && [ ! -f "${stock_apk}.apkm" ]; then
		if [ -f "${TEMP_DIR}/${pkg_name}-${version_f}-all.apk" ] || [ -f "${TEMP_DIR}/${pkg_name}-${version_f}-all.apkm" ]; then
			stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-all.apk"
			abi=all
		fi
	fi
	if [ "$unknown_ver" = true ] || { [ ! -f "$stock_apk" ] && [ ! -f "${stock_apk}.apkm" ]; }; then
		# version_f is the literal "latest" here, so the name can't be predicted and a
		# leftover from a previous run would satisfy the check below even if the
		# download never produced anything
		rm -f "${stock_apk}" "${stock_apk}.apkm" "${stock_apk}.ver" || :
		pr "Downloading '${table}' via apk-fetch (${version_f})"
		# archive-dlurl is tried first since it's more reliable for a pinned version; apk-fetch
		# (apkcombo -> apkpure -> apkmirror) is the fallback. with no version, the provider picks
		# its own latest and leaves it in "$stock_apk.ver". split bundles (.apkm/.xapk) land next
		# to it as "${stock_apk}.apkm"; the patcher merges those itself.
		if ! bash ./dl-apk.sh "$pkg_name" "$archive_url" "$stock_apk" "${version// /}"; then
			epr "ERROR: Could not download '${table}' with version '${version_f}'"
			return 0
		fi
		if [ -f "${stock_apk}.ver" ]; then
			version=$(cat "${stock_apk}.ver")
			rm -f "${stock_apk}.ver"
			version_f=${version// /}
			version_f=${version_f#v}
		fi
		if [ ! -f "$stock_apk" ] && [ ! -f "${stock_apk}.apkm" ]; then
			epr "Stock apk not found ($stock_apk)"
			return 0
		fi
		if [ "$version_f" = latest ]; then
			epr "no version reported for '${table}'."
			return 0
		fi
	fi

	pr "Choosing version '${version}' for ${table}"

	local sig_op
	if [ -f "${stock_apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		for a in "${stock_apk}"-zip/*.apk; do
			if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch '$a': $sig_op"
				return 0
			fi
		done
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi
	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} == *"${microg_patch}"* ]]; then
		epr "You cant include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	if [ -n "$microg_patch" ]; then p_patcher_args+=("-e \"${microg_patch}\""); fi

	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	pr "Building '${table}'"

	local patched_apk="${TEMP_DIR}/${app_name_l}-morphe-${version_f}-${abi}.apk"
	local apk_output="${BUILD_DIR}/${app_name_l}-morphe-v${version_f}-${abi}.apk"
	# split bundles land next to it as "${stock_apk}.apkm"; the patcher merges those itself
	[ -f "$stock_apk" ] || stock_apk="${stock_apk}.apkm"
	if ! patch_apk "$stock_apk" "$patched_apk" "${p_patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
		epr "Building '${table}' failed!"
		return 0
	fi
	mv -f "$patched_apk" "$apk_output"
	# logged only after the build succeeds, so failed versions never reach the release notes
	log "${table}: ${version}"
	pr "Built ${table}: '${apk_output}'"
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

