#!/usr/bin/env bash

_CACHE_SH_PATH="${_CACHE_SH_PATH:-$(dirname "${BASH_SOURCE[0]:-./}")/cache.sh}"

if [ -f "$_CACHE_SH_PATH" ]; then
	# shellcheck disable=SC1090
	source "$_CACHE_SH_PATH"
else
	echo >&2 "utils.sh: WARNING — cache.sh not found at $_CACHE_SH_PATH"
	echo >&2 "utils.sh: continuing with legacy inline cache logic DISABLED"
fi

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("direct" "archive" "apkmirror" "uptodown")

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$($TOML --output json --file "$1" .)
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
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
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

# -----------------------------------------------------------------------------
# Logging — colored + GitHub Actions annotation aware
# -----------------------------------------------------------------------------
pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
# New info-style logger — used for the version banner and stale-cache messages.
# NOTE: writes to STDERR on purpose. get_prebuilts() returns its result on
# stdout and the caller captures it, so logs must never go to stdout.
ipr() {
	echo >&2 -e "\033[0;36m[i] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::group::utils.sh [i] ${1}"; fi
}
okr() { echo >&2 -e "\033[0;32m[OK] ${1}\033[0m"; }

_clean_tmp() {
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*tmp_* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./*-temporary-files
}

abort() {
	epr "ABORT: ${1-}"
	_clean_tmp
	trap - SIGTERM SIGINT EXIT
	kill -9 -- -$$ 2>/dev/null
	exit 1
}

java() {
	if [ "${JAVA_HOME_21_X64-}" ]; then
		env -i JAVA_HOME="$JAVA_HOME_21_X64" "$JAVA_HOME_21_X64"/bin/java --enable-native-access=ALL-UNNAMED "$@"
	else
		env -i java --enable-native-access=ALL-UNNAMED "$@"
	fi
}

# =============================================================================
# Version helpers
# =============================================================================

# semver_validate <ver>
# Returns 0 (true) if $1 looks like X.Y.Z (with optional -suffix and/or leading v).
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}

# semver_sort_desc
# Reads version strings from stdin, sorts them in DESCENDING semver order.
# Examples:
#   v1.17.0-dev.2
#   v1.17.0-dev.1
#   v1.16.0
#   v1.14.0
# Implementation:
#   - Strip leading "v" for sort key consistency.
#   - Use `sort -V` (version sort) which understands dotted numbers and
#     pre-release suffixes correctly. Reverse for descending.
#   - Output keeps the original "v" prefix intact.
semver_sort_desc() {
	awk '{
		v=$0; sub(/^v/,"",v);   # strip leading v for sorting
		print v"\t"$0
	}' | sort -t$'\t' -k1,1Vr | cut -f2-
}

# get_highest_ver
# Reads version strings (one per line) from stdin, prints the highest one.
# Falls back to plain head -1 if the first line isn't a valid semver
# (keeps backward compatibility with non-semver strings).
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else semver_sort_desc <<<"$vers" | head -1; fi
}

# extract_version_from_filename <filename>
# Echoes the version substring embedded in a JAR filename, e.g.:
#   morphe-desktop-1.16.0-all.jar  -> 1.16.0
#   morphe-patches-1.43.0-dev.6.jar -> 1.43.0-dev.6
#   revanced-cli-4.0.0-all.jar     -> 4.0.0
extract_version_from_filename() {
	local name
	name=$(basename "$1")
	# Strip known prefixes
	name="${name#morphe-desktop-}"
	name="${name#morphe-cli-}"
	name="${name#morphe-patches-}"
	name="${name#revanced-cli-}"
	name="${name#revanced-patches-}"
	# Strip known suffixes
	name="${name%-all.jar}"
	name="${name%.jar}"
	# Strip any trailing "-<something>" that's not part of the version
	# (e.g., -dev.2 stays because it's part of semver pre-release)
	echo "$name"
}

# resolve_version <repo> <selector>
# Echoes "<tag_name> <asset_name>" for the resolved release.
# Selector can be: "latest" | "stable" | "dev" | "vX.Y.Z" | "X.Y.Z"
# Returns 1 on failure (network error, no asset found).
#
# Implementation notes:
#   - "stable" is treated as alias for "latest" (GitHub's /releases/latest
#     endpoint already excludes pre-releases, which IS the stable definition).
#   - For "dev", we list ALL releases and pick the highest semver (including
#     -dev.N tags). This is what the previous code intended but its file-picker
#     logic was the actual bug — we now resolve the tag here and use it as
#     an exact-match key in the cache, never a glob.
resolve_version() {
	local repo="$1" sel="$2"
	local rv_rel="https://api.github.com/repos/${repo}/releases"
	local resp tag_name asset_name matches

	# Normalize selector
	sel="${sel#v}" # tolerate "v1.16.0" — strip leading v for compare

	case "$sel" in
	latest | stable)
		# GitHub's /releases/latest endpoint excludes pre-releases
		# and returns the SAME shape as a single-tag fetch — including
		# the .assets[] array. One HTTP call, no re-fetch needed.
		resp=$(gh_req "$rv_rel/latest" -) || { epr "resolve_version: /releases/latest failed for $repo"; return 1; }
		tag_name=$(jq -r '.tag_name' <<<"$resp")
		;;
	dev)
		# List ALL releases once. The list response already contains
		# the .assets[] array for every entry, so we don't need to
		# re-fetch the chosen tag — we just pick the entry whose
		# tag_name matches our resolved one.
		resp=$(gh_req "$rv_rel" -) || { epr "resolve_version: list releases failed for $repo"; return 1; }
		tag_name=$(jq -r '.[].tag_name' <<<"$resp" | semver_sort_desc | head -1)
		if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
			epr "resolve_version: no releases found for $repo"
			return 1
		fi
		# Narrow resp to the single entry that matches the resolved tag.
		resp=$(jq -r --arg t "$tag_name" '.[] | select(.tag_name == $t)' <<<"$resp")
		;;
	*)
		# Explicit pin — fetch the specific tag. /releases/tags/<tag>
		# returns the same shape as /releases/latest, including
		# .assets[], so no further call is required.
		resp=$(gh_req "$rv_rel/tags/v${sel}" -) || { epr "resolve_version: tag v${sel} not found for $repo"; return 1; }
		tag_name=$(jq -r '.tag_name' <<<"$resp")
		;;
	esac

	if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
		epr "resolve_version: empty tag for $repo (selector=$sel)"
		return 1
	fi

	# Pick the FIRST non-signature, non-json asset.
	# Single-asset releases are the norm for both morphe-desktop and morphe-patches.
	matches=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not))' <<<"$resp")
	if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
		epr "resolve_version: no downloadable asset in tag ${tag_name} of $repo"
		return 1
	elif [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
		wpr "resolve_version: multiple assets in ${tag_name}, picking the first"
	fi
	asset_name=$(jq -r '.[0].name' <<<"$matches")

	echo "${tag_name} ${asset_name}"
}

# purge_stale_jars <dir> <keep_basename>
# Deletes every regular file in <dir> whose basename shares the same
# "kind" prefix as <keep_basename> but is NOT <keep_basename> itself.
#
# The "kind" prefix is derived from <keep_basename> by stripping everything
# from the first "-<digit>" onward — i.e., the version-less stem.
# Examples:
#   keep="morphe-desktop-1.16.0-all.jar"   -> kind="morphe-desktop"
#   keep="patches-1.43.0.mpp"              -> kind="patches"
#   keep="revanced-cli-4.0.0-all.jar"      -> kind="revanced-cli"
#
# Important: the find pattern is "${kind}-*" with NO extension filter, so it
# matches any extension (.jar, .mpp, .zip, etc.). This was a real bug in the
# first version of this helper, which only looked for .jar and silently missed
# morphe-patches' .mpp assets.
purge_stale_jars() {
	local dir="$1" keep="$2"
	[ -d "$dir" ] || return 0

	# Derive kind: strip from the first "-<digit>" onward.
	# The pattern %%-[0-9]* matches the first occurrence of -<digit> followed
	# by anything, and removes it. Works for any ASCII digit 0-9.
	local kind="${keep%%-[0-9]*}"
	if [ "$kind" = "$keep" ]; then
		# No version pattern detected — nothing to purge.
		return 0
	fi

	local f
	while IFS= read -r -d '' f; do
		local b
		b=$(basename "$f")
		if [ "$b" != "$keep" ]; then
			wpr "Purging stale cached artifact: $b (keeping $keep)"
			rm -f "$f"
		fi
	done < <(find "$dir" -maxdepth 1 -type f -name "${kind}-*" -print0 2>/dev/null)
}

# verify_jar <jar>
# Returns 0 if the JAR is a readable zip/JAR, 1 otherwise.
# We use `unzip -l` because it's already a script dependency (see build.sh).
# This catches partial downloads and corrupted files.
verify_jar() {
	local jar="$1"
	[ -f "$jar" ] || return 1
	unzip -l "$jar" >/dev/null 2>&1
}

# print_version_banner <cli_repo> <cli_tag> <cli_asset> <patches_repo> <patches_tag> <patches_asset>
# Pretty-prints the [INFO] block the user requested.
print_version_banner() {
	ipr "─────────── version banner ───────────"
	ipr "CLI     : $1 @ $2 ($3)"
	ipr "Patches : $4 @ $5 ($6)"
	ipr "───────────────────────────────────────"
}

# =============================================================================
# Prebuilts — refactored
# =============================================================================

# get_prebuilts <cli_src> <cli_ver> <patches_src> <patches_ver>
# Echoes "<patches_jar_path> <cli_jar_path>" on stdout (same shape as before).
# Side effects:
#   - Resolves exact tag + asset name for both CLI and patches via GitHub API.
#   - Reuses cached files ONLY if their basename matches the resolved asset
#     name exactly. Otherwise the cached file is purged and a fresh one is
#     downloaded.
#   - Calls verify_jar() on the final files and refuses to use a corrupted JAR.
#   - Emits [INFO]/[OK]/[WARN]/[ERROR] log lines for every decision.
get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2

	# Ensure CACHE_DIR (used by cache.sh) points to the same dir as TEMP_DIR
	# so the rest of build_rv's stock-APK cache layout still works.
	CACHE_DIR="${CACHE_DIR:-$TEMP_DIR}"

	# The org-derived temp subdir (e.g. "temp/morpheapp-rv") is where both
	# CLI and patches JARs live. We set CACHE_DIR to that path so cache.sh
	# operates on the right directory.
	local cl_dir=${patches_src%/*}
	cl_dir=${TEMP_DIR}/${cl_dir,,}-rv
	CACHE_DIR="$cl_dir"
	export CACHE_DIR
	[ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR"

	local out_files=""
	local resolved_cli_tag resolved_cli_asset resolved_patches_tag resolved_patches_asset

	# Build a hash of the build-affecting parameters so the cache key
	# invalidates when config.toml changes (even if the tag stays the same).
	# For simplicity we hash the resolved config + cli + patches selectors.
	local bp_hash
	bp_hash=$(printf '%s|%s|%s|%s' "$cli_src" "$cli_ver" "$patches_src" "$patches_ver" \
		| sha256sum | awk '{print $1}' | cut -c1-16)

	for src_ver in "Patches $patches_src $patches_ver" "CLI $cli_src $cli_ver"; do
		set -- $src_ver
		local tag=$1 src=$2 ver=${3-}

		ipr "Resolving $tag: $src @ $ver"

		local identity
		if ! identity=$(cache_resolve_identity "$src" "$ver" "linux" "$(uname -m)" "$bp_hash" 2>/dev/null); then
			epr "Failed to resolve $tag ($src @ $ver)"
			return 1
		fi

		local tag_name asset_name
		tag_name=$(_cache_identity_get "$identity" tag)
		asset_name=$(_cache_identity_get "$identity" artifact_name)
		okr "Resolved $tag: tag=$tag_name asset=$asset_name"

		if [ "$tag" = "CLI" ]; then
			resolved_cli_tag=$tag_name
			resolved_cli_asset=$asset_name
		else
			resolved_patches_tag=$tag_name
			resolved_patches_asset=$asset_name
		fi

		# cache_get does everything: lookup, purge_stale, download, store,
		# fallback if download fails. Returns the local path on stdout.
		local url="https://github.com/${src}/releases/download/${tag_name}/${asset_name}"
		local expected_file
		if ! expected_file=$(cache_get "$identity" "$url" 2>&1); then
			epr "cache_get failed for $tag ($src @ $ver)"
			return 1
		fi

		# cache_get may have logged to stderr; the actual file path is the
		# last line of stdout that doesn't start with [CACHE].
		expected_file=$(grep -v '^\[CACHE\]' <<<"$expected_file" | tail -1)
		[ -f "$expected_file" ] || {
			epr "cache_get returned no usable path for $tag"
			return 1
		}
		okr "$tag artifact ready at: $expected_file"

		# If this is the Patches JAR and we want to strip revanced-integrations
		# checks (kept identical to the original behavior).
		if [ "$tag" = "Patches" ]; then
			if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
				local extensions_ext
				extensions_ext=$(unzip -l "${expected_file}" "extensions/shared.*" | grep -o "shared\..*") extensions_ext="${extensions_ext#*.}"
				if ! (
					mkdir -p "${expected_file}-zip" || return 1
					unzip -qo "${expected_file}" -d "${expected_file}-zip" || return 1
					java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${expected_file}-zip/extensions/shared.${extensions_ext}" "${expected_file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
					mv -f "${expected_file}-zip/extensions/shared-patched.${extensions_ext}" "${expected_file}-zip/extensions/shared.${extensions_ext}" || return 1
					rm "${expected_file}" || return 1
					cd "${expected_file}-zip" || abort
					zip -0rq "${CWD}/${expected_file}" . || return 1
				) >&2; then
					echo >&2 "Patching revanced-integrations failed"
				fi
				rm -r "${expected_file}-zip" || :
			fi
			echo "[Changelog](https://github.com/${src}/releases/tag/${tag_name})" >>"${cl_dir}/changelog.md"
		fi

		out_files+="${expected_file} "
	done

	print_version_banner \
		"$cli_src" "$resolved_cli_tag" "$resolved_cli_asset" \
		"$patches_src" "$resolved_patches_tag" "$resolved_patches_asset"

	# Final cross-check: can the CLI JAR actually list patches from this
	# patches JAR? This catches NoClassDefFoundError / IncompatibleClassChange
	# BEFORE we waste minutes downloading stock APKs.
	local cli_jar patches_jar
	read -r patches_jar cli_jar <<<"$out_files"
	ipr "Running pre-flight compatibility check (java -jar CLI list-patches ...)"
	local probe
	if probe=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "com.google.android.youtube" --versions --packages -b 2>&1); then
		okr "Pre-flight compatibility check passed."
	else
		# Don't hard-fail — the original script tolerated partial mismatches
		# (some apps may not be supported). But warn loudly so the user sees
		# the early signal in the log.
		wpr "Pre-flight check returned non-zero: ${probe:0:200}"
		wpr "If a downstream patches_list() call fails with NoClassDefFoundError, the CLI and patches versions are incompatible."
	fi

	echo "$out_files"
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="${BIN_DIR}/toml/tq-${arch}"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [[ -v sources["$PATCHES_SRC/$PATCHES_VER"] ]]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			# Use resolve_version so "stable" and explicit pin both work here too.
			local resolved tag_name asset_name
			if ! resolved=$(resolve_version "$PATCHES_SRC" "$PATCHES_VER"); then
				wpr "config_update: resolve_version failed for $PATCHES_SRC @ $PATCHES_VER — skipping"
				continue
			fi
			read -r tag_name asset_name <<<"$resolved"
			last_patches=$asset_name
			if [ "$last_patches" ]; then
				if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep -m1 "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

# =============================================================================
# Network helpers (unchanged behavior)
# =============================================================================

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 --fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:108.0) Gecko/20100101 Firefox/108.0"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }

# get_highest_ver is defined above (kept near the new helpers).

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
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			semver_sort_desc <<<"$vers" | head -1
		fi
	fi
}

patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local op cmd_base cmd cli_name
	cmd_base="java -jar '$cli_jar' list-versions"
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd_base+=" -b"; fi
	cmd="$cmd_base -p '$patches_jar' -f '$pkg_name'"
	if [ "$is_experimental" = "true" ]; then cmd+=" -x"; fi
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi
	cmd="${cmd_base} '$patches_jar' -f '$pkg_name'"
	if op=$(eval "$cmd" 2>&1); then
		echo "$op"
		return
	fi
	epr "Could not list versions ($pkg_name) $cli_jar: '$op'"
	return 1
}

patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 is_experimental=$4
	local op
	if ! op=$(java -jar "$cli_jar" list-patches -p "$patches_jar" --filter-package-name "$pkg_name" --versions --packages -b 2>&1); then
		local cmd="java -jar '$cli_jar' list-patches --patches '$patches_jar' -f '$pkg_name' --with-versions --with-packages"
		if [ "$is_experimental" = "true" ]; then cmd+=" -x"; fi
		if ! op=$(eval "$cmd" 2>&1); then
			epr "Could not get patches list ($pkg_name) $cli_jar: '$op'"
			epr "This usually means the CLI version and patches version are incompatible (e.g., CLI bundles an older morphe-patcher than the patches JAR was compiled against). Pin cli-version to a known-good tag in config.toml."
			return 1
		fi
	fi
	echo "$op"
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	pr "Merging splits"
	gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar" >/dev/null || return 1
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		return 1
	fi
}

# Stock APK downloaders below this point — unchanged from the original script
# (kept verbatim so the rest of build_rv keeps working).

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local tmp_files
	tmp_files="$(pwd)/$(mktemp -d -p "$TEMP_DIR")"
	local cmd="java -jar '$cli_jar' patch '$stock_input' -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc -t '$tmp_files' $patcher_args"
	local cli_name
	cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then cmd+=" -b"; fi
	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary='${AAPT2}'"; fi
	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l=${app_name,,}
	app_name_l=${app_name_l// /-}
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "${args[excluded_patches]}" ]; then p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)"); fi
	if [ "${args[included_patches]}" ]; then p_patcher_args+=("$(join_args "${args[included_patches]}" -e)"); fi
	[ "${args[exclusive_patches]}" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	if [ "${args[pkg_name]}" ]; then
		pkg_name="${args[pkg_name]}"
	else
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
				args[${dl_p}_dlurl]=""
				epr "ERROR: Could not find ${table} in ${dl_p}"
				continue
			fi
			tried_dl+=("$dl_p")
			dl_from=$dl_p
			break
		done
	fi
	if [ -z "$pkg_name" ]; then
		epr "empty pkg name, not building ${table}."
		return 0
	fi
	pr "Package name of '${table}' is '$pkg_name'"

	local list_patches
	local is_experimental="false"
	if [ "$version_mode" = "experimental" ]; then is_experimental="true"; fi
	list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$is_experimental") || return 1

	local get_latest_ver=false
	if isoneof "$version_mode" "auto" "experimental"; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" "${args[included_patches]}" "$is_experimental"); then
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return
		elif [ -z "$version" ]; then get_latest_ver="true"; fi
	elif [ "$version_mode" = "latest" ]; then
		get_latest_ver="true"
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = "true" ]; then
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		return 0
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi

	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in "${DL_SRCS[@]}"; do
			if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then
			epr "Stock apk not found ($stock_apk)"
			return 0
		fi
	fi

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

	log "${table}: ${version}"

	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	if [ -n "$microg_patch" ] && [[ ${p_patcher_args[*]} =~ $microg_patch ]]; then
		wpr "You cant include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local patcher_args patched_apk build_mode
	local rv_brand_f=${args[rv_brand],,}
	rv_brand_f=${rv_brand_f// /-}
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patcher_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patcher_args+=("-d \"${microg_patch}\"")
			fi
		fi

		local stock_apk_to_patch="${stock_apk}.stripped.apk"
		cp -f "$stock_apk" "$stock_apk_to_patch"
		if [ "$build_mode" = module ]; then
			zip -d "$stock_apk_to_patch" "lib/*" >/dev/null 2>&1 || :
		else
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
		fi

		local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi
		rm "$stock_apk_to_patch"

		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			continue
		fi

		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="${table,,}-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"

		local patches_ver="${patches_jar##*-}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${args[rv_brand]}" \
			"${version} (patches ${patches_ver})" \
			"${app_name} ${args[rv_brand]} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"
		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			if [ "${args[include_stock]}" = "merged" ]; then
				cp -f "$stock_apk" "${base_template}/stock/base.apk"
			elif [ "${args[include_stock]}" = "split" ]; then
				if [ ! -f "${stock_apk}.apkm" ]; then
					epr "Cannot include as 'split' because stock apk of $table_name is not a bundle"
					return 0
				fi
				if [ "$arch" = "arm64-v8a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "arm-v7a" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86_64" ]; then
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				else
					unzip -j "${stock_apk}.apkm" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=Zhibarie
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
