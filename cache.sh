#!/usr/bin/env bash
# =============================================================================
# cache.sh — Artifact cache library (identity-based, atomic, concurrent-safe)
# =============================================================================
#
# Public API:
#   cache_resolve_identity <repo> <selector> [platform] [arch] [build_params_hash]
#       -> echoes a single-line identity: "k=v k=v ..." (or returns 1)
#   cache_compute_key <identity>
#       -> echoes a deterministic cache key string
#   cache_lookup <identity>
#       -> returns 0 (hit) + path on stdout, or 1 (miss) + reason on stderr
#   cache_store <identity> <downloaded_file_path>
#       -> returns 0 on success, 1 on failure (with reason on stderr)
#   cache_purge_stale <identity>
#       -> keeps identity's artifact, marks others of same kind as stale;
#          applies retention policy (deletes overflow)
#   cache_fallback <identity> <reason>
#       -> returns 0 + path if fallback allowed and a valid old version exists
#   cache_get <identity> <download_url>
#       -> main entry; combines lookup + (miss -> download + store) + fallback
#
# Cache layout (under $CACHE_DIR, default "temp"):
#   <CACHE_DIR>/<artifact_name>          # the artifact file
#   <CACHE_DIR>/<artifact_name>.meta     # JSON sidecar with identity + status
#   <CACHE_DIR>/index.json               # master index (status of all artifacts)
#   <CACHE_DIR>/.lock                    # flock() lock for atomic updates
#
# Identity fields (from GitHub API release + caller-provided):
#   artifact_name    — exact basename from GitHub release asset (e.g.
#                      "morphe-desktop-1.16.0-all.jar" or "patches-1.43.0.mpp")
#   source_repo      — "OWNER/REPO" (e.g. "MorpheApp/morphe-desktop")
#   tag              — release tag_name (e.g. "v1.16.0")
#   commit_sha       — release target_commitish (short, 8 chars; may be empty)
#   checksum         — sha256 from asset.digest (the EXPECTED one from API)
#   size             — asset.size in bytes
#   platform         — "linux" (only "linux" is supported in CI runners;
#                      recorded for portability)
#   arch             — "x86_64" / "arm64" / "arm-v7a" / etc.
#   build_params_hash — sha256 of build-affecting params (config + cli + patches)
#
# All operations are deterministic given the same inputs. No time-based
# decisions are made except for the optional "valid_until" retention field
# which is explicit metadata, not implicit.
# =============================================================================

# ---- Configuration (override via env) ---------------------------------------
CACHE_DIR="${CACHE_DIR:-temp}"
CACHE_LOCK_TIMEOUT="${CACHE_LOCK_TIMEOUT:-30}"             # seconds to wait for lock
CACHE_RETENTION_COUNT="${CACHE_RETENTION_COUNT:-2}"       # keep N versions per "kind" (default 2 for rollback)
CACHE_RETENTION_AGE_DAYS="${CACHE_RETENTION_AGE_DAYS:-30}" # delete artifacts older than N days (0 = disable)
CACHE_FALLBACK_ALLOWED="${CACHE_FALLBACK_ALLOWED:-true}"   # use stale cache on download failure
CACHE_FALLBACK_STATUS="${CACHE_FALLBACK_STATUS:-stale}"    # which statuses are eligible for fallback

# ---- Logging ----------------------------------------------------------------
# Structured key=value, easy to grep. Also emits GitHub Actions annotations
# when running under GITHUB_REPOSITORY.
_cache_log() {
        local level="$1"; shift
        local msg="$*"
        echo >&2 "[CACHE] level=$level $msg"
        if [ "${GITHUB_REPOSITORY-}" ]; then
                case "$level" in
                        error) echo "::error::[CACHE] $msg" >&2 ;;
                        warn)  echo "::warning::[CACHE] $msg" >&2 ;;
                esac
        fi
}
cache_log_info()  { _cache_log info  "$@"; }
cache_log_ok()    { _cache_log ok    "$@"; }
cache_log_warn()  { _cache_log warn  "$@"; }
cache_log_error() { _cache_log error "$@"; }

# ---- Identity helpers -------------------------------------------------------

# _cache_identity_get <identity> <key>
# Echoes the value of <key> from an identity string. Returns 1 if not found.
_cache_identity_get() {
        local identity="$1" key="$2"
        local kv
        kv=$(grep -oE "${key}=[^ ]+" <<<"$identity ")
        [ -z "$kv" ] && return 1
        echo "${kv#${key}=}"
}

# cache_compute_key <identity>
# Deterministic cache key derived from all identity components.
# Format: <repo_safe>-<tag>-<sha8>-<checksum8>-<platform>-<arch>-<bp_hash8>
cache_compute_key() {
        local identity="$1"
        local repo tag sha checksum platform arch bp
        repo=$(_cache_identity_get "$identity" source_repo   || echo "unknown")
        tag=$(_cache_identity_get "$identity" tag            || echo "0")
        sha=$(_cache_identity_get "$identity" commit_sha     || echo "")
        checksum=$(_cache_identity_get "$identity" checksum  || echo "")
        platform=$(_cache_identity_get "$identity" platform  || echo "any")
        arch=$(_cache_identity_get "$identity" arch          || echo "any")
        bp=$(_cache_identity_get "$identity" build_params_hash || echo "")

        local repo_safe="${repo//\//-}"
        local sha8="${sha:0:8}"
        local checksum8="${checksum:0:8}"
        local bp8="${bp:0:8}"
        echo "${repo_safe}-${tag}-${sha8}-${checksum8}-${platform}-${arch}-${bp8}"
}

# ---- File primitives --------------------------------------------------------

# _cache_meta_path <artifact_name>
# Echoes the path to the .meta sidecar for a given artifact.
_cache_meta_path() {
        local artifact="$1"
        echo "${CACHE_DIR}/${artifact}.meta"
}

# _cache_index_path
# Echoes the path to index.json.
_cache_index_path() {
        echo "${CACHE_DIR}/index.json"
}

# _cache_lock_path
# Echoes the path to the flock file.
_cache_lock_path() {
        echo "${CACHE_DIR}/.lock"
}

# _cache_sha256 <file>
# Echoes the sha256 hex digest of <file>. Returns 1 if file doesn't exist.
_cache_sha256() {
        local file="$1"
        [ -f "$file" ] || return 1
        sha256sum "$file" | awk '{print $1}'
}

# _cache_meta_read <artifact_name>
# Echoes the .meta JSON content. Returns 1 if missing or invalid JSON.
_cache_meta_read() {
        local artifact="$1"
        local meta
        meta=$(_cache_meta_path "$artifact")
        [ -f "$meta" ] || return 1
        jq -e '.' "$meta" 2>/dev/null || return 1
}

# _cache_meta_write <artifact_name> <json>
# Writes the .meta sidecar atomically (write to temp, then mv).
_cache_meta_write() {
        local artifact="$1" json="$2"
        local meta tmp
        meta=$(_cache_meta_path "$artifact")
        tmp="${meta}.tmp.$$"
        printf '%s\n' "$json" >"$tmp" || return 1
        mv -f "$tmp" "$meta"
}

# _cache_meta_field <artifact_name> <field>
# Echoes a single field from the .meta JSON. Returns 1 if missing.
_cache_meta_field() {
        local artifact="$1" field="$2"
        local meta_json
        meta_json=$(_cache_meta_read "$artifact") || return 1
        jq -r --arg f "$field" '.[$f] // empty' <<<"$meta_json"
}

# ---- Index management -------------------------------------------------------

# _cache_index_read
# Echoes the index.json content. If missing, echoes an empty index.
_cache_index_read() {
        local idx
        idx=$(_cache_index_path)
        if [ ! -f "$idx" ]; then
                echo '{"version":1,"artifacts":{}}'
                return 0
        fi
        cat "$idx"
}

# _cache_index_update <artifact_name> <status>
# Updates index.json with the status of <artifact_name>. Atomic.
_cache_index_update() {
        local artifact="$1" status="$2"
        local idx tmp
        idx=$(_cache_index_path)
        tmp="${idx}.tmp.$$"
        mkdir -p "$CACHE_DIR"
        # Read existing, set the entry, write back
        _cache_index_read \
                | jq -e --arg a "$artifact" --arg s "$status" --arg m "${artifact}.meta" \
                        '.version as $v | .artifacts[$a] = {"meta_path":$m, "status":$s} | .version = $v' \
                        >"$tmp" || return 1
        mv -f "$tmp" "$idx"
}

# ---- Locking ----------------------------------------------------------------

# _cache_lock_acquire <fd_var>
# Opens the lock file and acquires an exclusive flock. Sets the FD in the
# named variable <fd_var>. Returns 1 if lock acquisition times out.
_cache_lock_acquire() {
        local -n fd_ref="$1"
        local lock
        lock=$(_cache_lock_path)
        mkdir -p "$CACHE_DIR"
        exec {fd_ref}>"$lock" || return 1
        if ! flock -w "$CACHE_LOCK_TIMEOUT" -x "$fd_ref"; then
                cache_log_error "operation=lock_acquire status=timeout timeout=${CACHE_LOCK_TIMEOUT}s"
                # Close the fd so it doesn't leak
                exec {fd_ref}>&-
                return 1
        fi
        return 0
}

# _cache_lock_release <fd>
# Releases the lock by closing the FD.
_cache_lock_release() {
        local fd="$1"
        exec {fd}>&-
}

# ---- Identity resolution (calls GitHub API) ----------------------------------

# cache_resolve_identity <repo> <selector> [platform] [arch] [build_params_hash]
# Echoes a single-line identity string with k=v pairs.
# Selector: latest | stable | dev | vX.Y.Z | X.Y.Z
# Returns 1 on failure (network, no asset).
cache_resolve_identity() {
        local repo="$1" sel="$2"
        local platform="${3:-linux}"
        local arch="${4:-x86_64}"
        local build_params_hash="${5:-}"

        local rv_rel="https://api.github.com/repos/${repo}/releases"
        local resp tag_name asset_name asset_digest asset_size commit_sha

        sel="${sel#v}"
        case "$sel" in
                latest|stable)
                        resp=$(_cache_gh_req "$rv_rel/latest") || {
                                cache_log_error "operation=resolve_identity status=failed repo=$repo sel=$sel reason=api_call_failed"
                                return 1
                        }
                        ;;
                dev)
                        resp=$(_cache_gh_req "$rv_rel") || {
                                cache_log_error "operation=resolve_identity status=failed repo=$repo sel=$sel reason=api_call_failed"
                                return 1
                        }
                        tag_name=$(jq -r '.[].tag_name' <<<"$resp" | _cache_semver_sort_desc | head -1)
                        if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
                                cache_log_error "operation=resolve_identity status=failed repo=$repo sel=$sel reason=no_releases"
                                return 1
                        fi
                        # Narrow to the matching entry
                        resp=$(jq -r --arg t "$tag_name" '.[] | select(.tag_name == $t)' <<<"$resp")
                        ;;
                *)
                        resp=$(_cache_gh_req "$rv_rel/tags/v${sel}") || {
                                cache_log_error "operation=resolve_identity status=failed repo=$repo sel=$sel reason=tag_not_found"
                                return 1
                        }
                        ;;
        esac

        tag_name=$(jq -r '.tag_name' <<<"$resp")
        commit_sha=$(jq -r '.target_commitish // empty' <<<"$resp")
        # Truncate commit_sha to 8 chars for cache key brevity
        commit_sha="${commit_sha:0:8}"

        # Pick the first non-signature, non-json asset
        local asset_json
        asset_json=$(jq -e '.assets | map(select(.name | (endswith("asc") or endswith("json")) | not)) | .[0]' <<<"$resp")
        if [ -z "$asset_json" ] || [ "$asset_json" = "null" ]; then
                cache_log_error "operation=resolve_identity status=failed repo=$repo tag=$tag_name reason=no_downloadable_asset"
                return 1
        fi
        asset_name=$(jq -r '.name'        <<<"$asset_json")
        asset_size=$(jq -r '.size // 0'   <<<"$asset_json")
        asset_digest=$(jq -r '.digest // ""' <<<"$asset_json")
        # asset.digest is "sha256:abcd..." — strip the prefix
        asset_digest="${asset_digest#sha256:}"

        # If GitHub API didn't expose .digest, leave checksum empty (verify will
        # skip checksum comparison but still verify size + name + tag).
        local bp8="${build_params_hash:0:8}"

        echo "artifact_name=${asset_name} source_repo=${repo} tag=${tag_name} commit_sha=${commit_sha} checksum=${asset_digest} size=${asset_size} platform=${platform} arch=${arch} build_params_hash=${bp8}"
}

# _cache_gh_req <url>
# curl wrapper that injects Authorization header if GITHUB_TOKEN is set.
_cache_gh_req() {
        local url="$1"
        local hdrs=()
        if [ "${GITHUB_TOKEN-}" ]; then
                hdrs+=(-H "Authorization: token ${GITHUB_TOKEN}")
        fi
        curl -fsSL --connect-timeout 10 --retry 1 \
                -H "Accept: application/vnd.github+json" \
                "${hdrs[@]}" "$url"
}

# _cache_semver_sort_desc
# Reads version strings from stdin, sorts descending by semver.
_cache_semver_sort_desc() {
        awk '{
                v=$0; sub(/^v/,"",v);
                print v"\t"$0
        }' | sort -t$'\t' -k1,1Vr | cut -f2-
}

# ---- Lookup -----------------------------------------------------------------

# cache_lookup <identity>
# Returns 0 + path on stdout if cache HIT; 1 + reason on stderr if MISS/INVALID.
# Verifies:
#   1. Artifact file exists
#   2. .meta file exists and is valid JSON
#   3. .meta.source_repo / .tag / .commit_sha / .checksum / .size / .platform / .arch
#      all match identity
#   4. .meta.status == "valid"
#   5. Actual file sha256 matches .meta.checksum (and identity.checksum if non-empty)
#   6. Actual file size matches .meta.size (and identity.size)
cache_lookup() {
        local identity="$1"
        local artifact repo tag sha checksum size platform arch bp
        artifact=$(_cache_identity_get "$identity" artifact_name)
        repo=$(_cache_identity_get "$identity" source_repo)
        tag=$(_cache_identity_get "$identity" tag)
        sha=$(_cache_identity_get "$identity" commit_sha)
        checksum=$(_cache_identity_get "$identity" checksum)
        size=$(_cache_identity_get "$identity" size)
        platform=$(_cache_identity_get "$identity" platform)
        arch=$(_cache_identity_get "$identity" arch)
        bp=$(_cache_identity_get "$identity" build_params_hash)

        local file="${CACHE_DIR}/${artifact}"
        if [ ! -f "$file" ]; then
                cache_log_info "decision=miss artifact=$artifact reason=file_not_found"
                return 1
        fi

        local meta_json
        meta_json=$(_cache_meta_read "$artifact") || {
                cache_log_warn "decision=invalid artifact=$artifact reason=meta_missing_or_corrupt"
                return 1
        }

        # Compare each identity field against .meta
        local m_repo m_tag m_sha m_checksum m_size m_platform m_arch m_bp m_status
        m_repo=$(jq -r '.source_repo // empty'    <<<"$meta_json")
        m_tag=$(jq -r '.tag // empty'              <<<"$meta_json")
        m_sha=$(jq -r '.commit_sha // empty'       <<<"$meta_json")
        m_checksum=$(jq -r '.checksum // empty'    <<<"$meta_json")
        m_size=$(jq -r '.size // 0'                 <<<"$meta_json")
        m_platform=$(jq -r '.platform // empty'    <<<"$meta_json")
        m_arch=$(jq -r '.arch // empty'             <<<"$meta_json")
        m_bp=$(jq -r '.build_params_hash // empty' <<<"$meta_json")
        m_status=$(jq -r '.status // empty'        <<<"$meta_json")

        if [ "$m_status" != "valid" ]; then
                cache_log_warn "decision=invalid artifact=$artifact reason=meta_status_not_valid status=$m_status"
                return 1
        fi

        # Field-by-field comparison. Empty values are skipped (e.g., commit_sha
        # may not be available from the API for older releases).
        local fail=0
        [ -n "$repo"     ] && [ "$m_repo"     != "$repo"     ] && { cache_log_warn "decision=invalid artifact=$artifact reason=source_repo_mismatch expected=$repo actual=$m_repo";     fail=1; }
        [ -n "$tag"      ] && [ "$m_tag"      != "$tag"      ] && { cache_log_warn "decision=invalid artifact=$artifact reason=tag_mismatch expected=$tag actual=$m_tag";              fail=1; }
        [ -n "$sha"      ] && [ -n "$m_sha" ] && [ "$m_sha" != "$sha" ] && { cache_log_warn "decision=invalid artifact=$artifact reason=commit_sha_mismatch expected=$sha actual=$m_sha"; fail=1; }
        [ -n "$platform" ] && [ "$m_platform" != "$platform" ] && { cache_log_warn "decision=invalid artifact=$artifact reason=platform_mismatch expected=$platform actual=$m_platform"; fail=1; }
        [ -n "$arch"     ] && [ "$m_arch"     != "$arch"     ] && { cache_log_warn "decision=invalid artifact=$artifact reason=arch_mismatch expected=$arch actual=$m_arch";          fail=1; }
        [ -n "$bp"       ] && [ "$m_bp"       != "$bp"       ] && { cache_log_warn "decision=invalid artifact=$artifact reason=build_params_hash_mismatch expected=$bp actual=$m_bp";   fail=1; }

        if [ $fail -ne 0 ]; then return 1; fi

        # Checksum + size verification against the ACTUAL file
        local actual_size actual_sha
        actual_size=$(stat -c '%s' "$file" 2>/dev/null || stat -f '%z' "$file")
        actual_sha=$(_cache_sha256 "$file")

        if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null && [ "$actual_size" != "$size" ]; then
                cache_log_error "decision=invalid artifact=$artifact reason=size_mismatch expected=$size actual=$actual_size"
                # Mark as invalid (don't delete — let retention policy decide)
                _cache_set_status "$artifact" invalid "size_mismatch expected=$size actual=$actual_size"
                return 1
        fi

        # Checksum: identity.checksum is authoritative (from GitHub API asset.digest).
        # If empty (API didn't expose it), fall back to .meta.checksum (a record of
        # what we computed when we first stored the file). If both empty, skip.
        local expected_checksum="${checksum:-$m_checksum}"
        if [ -n "$expected_checksum" ] && [ "$actual_sha" != "$expected_checksum" ]; then
                cache_log_error "decision=invalid artifact=$artifact reason=checksum_mismatch expected=$expected_checksum actual=$actual_sha"
                _cache_set_status "$artifact" invalid "checksum_mismatch expected=$expected_checksum actual=$actual_sha"
                return 1
        fi

        cache_log_ok "decision=hit artifact=$artifact tag=$tag size=$actual_size checksum=$actual_sha"
        echo "$file"
        return 0
}

# _cache_set_status <artifact> <status> [reason]
# Updates .meta.status (atomic) and index.json (atomic). Caller must hold lock
# OR accept the small race (status updates are idempotent).
_cache_set_status() {
        local artifact="$1" status="$2" reason="${3:-}"
        local meta_json
        meta_json=$(_cache_meta_read "$artifact") || return 1
        local updated
        updated=$(jq --arg s "$status" --arg r "$reason" --arg t "$(date -u +%FT%TZ)" \
                '.status=$s | .status_reason=$r | .status_updated_at=$t' <<<"$meta_json")
        _cache_meta_write "$artifact" "$updated"
        _cache_index_update "$artifact" "$status"
}

# ---- Store ------------------------------------------------------------------

# cache_store <identity> <downloaded_file_path>
# Atomically:
#   1. Verifies checksum + size of <downloaded_file_path> against <identity>
#   2. Acquires lock
#   3. Moves file to its final location (atomic rename)
#   4. Writes .meta sidecar (atomic)
#   5. Updates index.json (atomic)
#   6. Releases lock
# Returns 0 on success, 1 on failure (with reason on stderr).
cache_store() {
        local identity="$1" src_file="$2"
        local artifact repo tag sha checksum size platform arch bp
        artifact=$(_cache_identity_get "$identity" artifact_name)
        repo=$(_cache_identity_get "$identity" source_repo)
        tag=$(_cache_identity_get "$identity" tag)
        sha=$(_cache_identity_get "$identity" commit_sha)
        checksum=$(_cache_identity_get "$identity" checksum)
        size=$(_cache_identity_get "$identity" size)
        platform=$(_cache_identity_get "$identity" platform)
        arch=$(_cache_identity_get "$identity" arch)
        bp=$(_cache_identity_get "$identity" build_params_hash)

        # Pre-flight: verify the downloaded file BEFORE acquiring the lock.
        # This avoids holding the lock during slow I/O.
        if [ ! -f "$src_file" ]; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=source_file_missing"
                return 1
        fi
        local actual_size actual_sha
        actual_size=$(stat -c '%s' "$src_file" 2>/dev/null || stat -f '%z' "$src_file")
        actual_sha=$(_cache_sha256 "$src_file")

        if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null && [ "$actual_size" != "$size" ]; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=size_mismatch expected=$size actual=$actual_size"
                rm -f "$src_file"
                return 1
        fi
        if [ -n "$checksum" ] && [ "$actual_sha" != "$checksum" ]; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=checksum_mismatch expected=$checksum actual=$actual_sha"
                rm -f "$src_file"
                return 1
        fi

        # If identity has no checksum from the API, fill it in from the downloaded
        # file's sha256 (so future lookups have something to compare against).
        if [ -z "$checksum" ]; then
                checksum="$actual_sha"
        fi

        # Acquire lock and do atomic write
        local fd
        if ! _cache_lock_acquire fd; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=lock_acquire_failed"
                return 1
        fi
        # shellcheck disable=SC2064
        trap "_cache_lock_release $fd" RETURN

        mkdir -p "$CACHE_DIR"
        local dest="${CACHE_DIR}/${artifact}"
        local tmp_dest="${dest}.tmp.$$"

        # Copy (not move) the source file to a temp path inside the cache dir.
        # We use cp because:
        #   1. The caller may want to keep the source (e.g., for fallback).
        #   2. Atomicity is still guaranteed by the rename step below.
        #   3. If cp fails (e.g., disk full), the cache stays clean.
        if ! cp -f "$src_file" "$tmp_dest"; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=copy_failed"
                _cache_lock_release "$fd"
                return 1
        fi
        # Atomic rename
        if ! mv -f "$tmp_dest" "$dest"; then
                rm -f "$tmp_dest"
                cache_log_error "operation=store status=failed artifact=$artifact reason=rename_failed"
                _cache_lock_release "$fd"
                return 1
        fi

        # Write .meta sidecar
        local meta_json
        meta_json=$(jq -n \
                --arg a "$artifact" \
                --arg r "$repo" \
                --arg t "$tag" \
                --arg s "$sha" \
                --arg c "$checksum" \
                --arg sz "$size" \
                --arg p "$platform" \
                --arg ar "$arch" \
                --arg bp "$bp" \
                --arg ct "$(date -u +%FT%TZ)" \
                '{artifact_name:$a, source_repo:$r, tag:$t, commit_sha:$s,
                  checksum:$c, size:$sz, platform:$p, arch:$ar,
                  build_params_hash:$bp, created_at:$ct,
                  status:"valid", status_reason:"", status_updated_at:$ct}')
        if ! _cache_meta_write "$artifact" "$meta_json"; then
                cache_log_error "operation=store status=failed artifact=$artifact reason=meta_write_failed"
                _cache_lock_release "$fd"
                return 1
        fi

        _cache_index_update "$artifact" "valid"

        cache_log_ok "operation=store status=ok artifact=$artifact tag=$tag size=$actual_size checksum=$actual_sha"
        _cache_lock_release "$fd"
        return 0
}

# ---- Purge + retention ------------------------------------------------------

# cache_purge_stale <identity>
# Marks every artifact of the same "kind" (derived from artifact_name prefix
# before first -<digit>) as "stale", EXCEPT the one matching <identity>.
# Then applies retention policy: if more than CACHE_RETENTION_COUNT stale
# entries exist for the kind, delete the oldest ones beyond the limit.
# Returns 0 always (purge is best-effort).
cache_purge_stale() {
        local identity="$1"
        local artifact
        artifact=$(_cache_identity_get "$identity" artifact_name)
        local kind="${artifact%%-[0-9]*}"
        if [ "$kind" = "$artifact" ] || [ -z "$kind" ]; then
                cache_log_warn "operation=purge_stale status=skipped artifact=$artifact reason=could_not_derive_kind"
                return 0
        fi

        mkdir -p "$CACHE_DIR"
        local fd
        if ! _cache_lock_acquire fd; then
                cache_log_error "operation=purge_stale status=failed reason=lock_acquire_failed"
                return 1
        fi
        # shellcheck disable=SC2064
        trap "_cache_lock_release $fd" RETURN

        # Find all files matching ${kind}-* (excluding .meta and .tmp and .lock files)
        local f b
        local stale_count=0
        local valid_count=0
        local -a stale_artifacts=()
        while IFS= read -r -d '' f; do
                # Skip .meta, .tmp, and .lock files explicitly
                case "$f" in
                        *.meta|*.tmp.*|*.lock|index.json) continue ;;
                esac
                b=$(basename "$f")
                if [ "$b" = "$artifact" ]; then
                        # The one we want to keep — ensure it's marked valid (no-op if already)
                        valid_count=$((valid_count + 1))
                        continue
                fi
                # Mark as stale (if currently valid)
                local cur_status
                cur_status=$(_cache_meta_field "$b" status 2>/dev/null || echo "unknown")
                if [ "$cur_status" = "valid" ] || [ "$cur_status" = "unknown" ]; then
                        _cache_set_status "$b" "stale" "superseded_by=$artifact"
                        stale_count=$((stale_count + 1))
                fi
                stale_artifacts+=("$b")
        done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name "${kind}-*" -print0 2>/dev/null)

        # Apply retention: keep at most CACHE_RETENTION_COUNT stale entries per kind.
        # Oldest by .meta.created_at are deleted first.
        if [ ${#stale_artifacts[@]} -gt "$CACHE_RETENTION_COUNT" ]; then
                local to_delete
                to_delete=$(( ${#stale_artifacts[@]} - CACHE_RETENTION_COUNT ))
                cache_log_info "operation=retention kind=$kind stale_count=${#stale_artifacts[@]} retention_limit=$CACHE_RETENTION_COUNT to_delete=$to_delete"

                # Sort stale artifacts by created_at ascending, delete oldest N
                local sorted
                sorted=$(for b in "${stale_artifacts[@]}"; do
                        local ct
                        ct=$(_cache_meta_field "$b" created_at 2>/dev/null || echo "1970-01-01T00:00:00Z")
                        echo "$ct $b"
                done | sort | head -n "$to_delete" | awk '{print $2}')

                while IFS= read -r b; do
                        [ -z "$b" ] && continue
                        cache_log_warn "operation=retention action=delete artifact=$b reason=exceeds_retention"
                        rm -f "${CACHE_DIR}/${b}" "${CACHE_DIR}/${b}.meta"
                        # Remove from index
                        local idx tmp
                        idx=$(_cache_index_path)
                        tmp="${idx}.tmp.$$"
                        _cache_index_read \
                                | jq -e --arg a "$b" 'del(.artifacts[$a])' \
                                >"$tmp" 2>/dev/null && mv -f "$tmp" "$idx" || rm -f "$tmp"
                done <<<"$sorted"
        fi

        cache_log_info "operation=purge_stale status=ok kind=$kind valid_count=$valid_count stale_marked=$stale_count retention_limit=$CACHE_RETENTION_COUNT"
        _cache_lock_release "$fd"
        return 0
}

# ---- Fallback ---------------------------------------------------------------

# cache_fallback <identity> <reason>
# If CACHE_FALLBACK_ALLOWED=true, look for the newest VALID artifact of the
# same kind that ISN'T the requested one, and return its path.
# Returns 0 + path on stdout, or 1 + reason on stderr.
cache_fallback() {
        local identity="$1" reason="$2"
        local artifact
        artifact=$(_cache_identity_get "$identity" artifact_name)
        local kind="${artifact%%-[0-9]*}"

        if [ "$CACHE_FALLBACK_ALLOWED" != "true" ]; then
                cache_log_error "decision=fallback_denied artifact=$artifact reason=$reason policy=fallback_disallowed"
                return 1
        fi

        if [ "$kind" = "$artifact" ] || [ -z "$kind" ]; then
                cache_log_error "decision=fallback_failed artifact=$artifact reason=could_not_derive_kind"
                return 1
        fi

        # Find all artifacts of same kind with status matching CACHE_FALLBACK_STATUS
        # (default: "stale"). Sort by created_at descending. Return the newest.
        local candidates=""
        local f b ct status
        while IFS= read -r -d '' f; do
                case "$f" in
                        *.meta|*.tmp.*|*.lock|index.json) continue ;;
                esac
                b=$(basename "$f")
                [ "$b" = "$artifact" ] && continue
                status=$(_cache_meta_field "$b" status 2>/dev/null || echo "unknown")
                # Accept any status in the fallback-eligible list (default: "stale")
                if [[ ",$CACHE_FALLBACK_STATUS," == *",$status,"* ]]; then
                        ct=$(_cache_meta_field "$b" created_at 2>/dev/null || echo "0")
                        candidates+="${ct} ${b}"$'\n'
                fi
        done < <(find "$CACHE_DIR" -maxdepth 1 -type f -name "${kind}-*" -print0 2>/dev/null)

        if [ -z "$candidates" ]; then
                cache_log_error "decision=fallback_failed artifact=$artifact reason=no_eligible_fallback kind=$kind"
                return 1
        fi

        local chosen
        chosen=$(sort -r <<<"$candidates" | head -1 | awk '{print $2}')
        if [ -z "$chosen" ]; then
                cache_log_error "decision=fallback_failed artifact=$artifact reason=no_candidate"
                return 1
        fi

        local chosen_tag chosen_path
        chosen_tag=$(_cache_meta_field "$chosen" tag 2>/dev/null || echo "unknown")
        chosen_path="${CACHE_DIR}/${chosen}"
        cache_log_warn "decision=fallback artifact=$artifact requested_tag=$(_cache_identity_get "$identity" tag) fallback_artifact=$chosen fallback_tag=$chosen_tag reason=$reason"
        echo "$chosen_path"
        return 0
}

# ---- Download helper (used by cache_get) ------------------------------------

# _cache_download <url> <dest_path>
# Downloads <url> to a temp file at <dest_path>.tmp.$$ and atomically renames
# on success. Returns 0 + path on stdout, or 1 + reason on stderr.
_cache_download() {
        local url="$1" dest="$2"
        local tmp="${dest}.tmp.$$"
        if [ "${GITHUB_TOKEN-}" ]; then
                if ! curl -fsSL --connect-timeout 10 --retry 1 \
                        -H "Authorization: token ${GITHUB_TOKEN}" \
                        -H "Accept: application/octet-stream" \
                        "$url" -o "$tmp"; then
                        rm -f "$tmp"
                        cache_log_error "operation=download status=failed url=$url reason=curl_failed"
                        return 1
                fi
        else
                if ! curl -fsSL --connect-timeout 10 --retry 1 \
                        -H "Accept: application/octet-stream" \
                        "$url" -o "$tmp"; then
                        rm -f "$tmp"
                        cache_log_error "operation=download status=failed url=$url reason=curl_failed"
                        return 1
                fi
        fi
        echo "$tmp"
        return 0
}

# ---- Main entry point -------------------------------------------------------

# cache_get <identity> <download_url>
# 1. Lookup: if HIT, return path (no download).
# 2. If MISS: purge stale, download, store.
#    - If download fails AND fallback allowed: use old valid cache.
#    - If download fails AND fallback disallowed: error.
# 3. Returns 0 + path on stdout, or 1 + reason on stderr.
cache_get() {
        local identity="$1" url="$2"
        local artifact tag
        artifact=$(_cache_identity_get "$identity" artifact_name)
        tag=$(_cache_identity_get "$identity" tag)
        local cache_key
        cache_key=$(cache_compute_key "$identity")

        cache_log_info "operation=cache_get artifact=$artifact tag=$tag cache_key=$cache_key"

        # Step 1: lookup
        local hit_path
        if hit_path=$(cache_lookup "$identity" 2>/dev/null); then
                cache_log_ok "operation=cache_get decision=hit artifact=$artifact tag=$tag"
                echo "$hit_path"
                return 0
        fi

        # Step 2: miss — purge stale, then download + store
        cache_purge_stale "$identity" || true

        cache_log_info "operation=cache_get decision=miss artifact=$artifact tag=$tag url=$url"

        local tmp_downloaded
        if ! tmp_downloaded=$(_cache_download "$url" "${CACHE_DIR}/${artifact}"); then
                cache_log_error "operation=cache_get status=failed artifact=$artifact tag=$tag reason=download_failed"
                # Try fallback
                local fallback_path
                if fallback_path=$(cache_fallback "$identity" "download_failed"); then
                        echo "$fallback_path"
                        return 0
                fi
                return 1
        fi

        if ! cache_store "$identity" "$tmp_downloaded"; then
                cache_log_error "operation=cache_get status=failed artifact=$artifact tag=$tag reason=store_failed"
                # Try fallback
                local fallback_path
                if fallback_path=$(cache_fallback "$identity" "store_failed"); then
                        echo "$fallback_path"
                        return 0
                fi
                return 1
        fi

        local final_path="${CACHE_DIR}/${artifact}"
        cache_log_ok "operation=cache_get decision=stored artifact=$artifact tag=$tag"
        echo "$final_path"
        return 0
}
