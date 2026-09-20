#!/usr/bin/env bash
# =============================================================================
# test_cache_bdd.sh — BDD tests for cache.sh
# =============================================================================
# Each test corresponds to one Scenario in the acceptance spec.
# Tests are pure-bash, deterministic, and use mocked I/O (no network, no
# real GitHub API calls).
#
# Run:
#   bash tests/test_cache_bdd.sh            # run all
#   bash tests/test_cache_bdd.sh 6          # run only scenario #6
#
# Exit codes:
#   0 = all passed
#   1 = at least one failed
# =============================================================================

set -uo pipefail

# ---- Test framework ---------------------------------------------------------

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
        local desc="$1" actual="$2" expected="$3"
        if [ "$actual" = "$expected" ]; then
                echo "    [OK] $desc"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc"
                echo "        expected: $expected"
                echo "        actual:   $actual"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

assert_ne() {
        local desc="$1" a="$2" b="$3"
        if [ "$a" != "$b" ]; then
                echo "    [OK] $desc"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc (both equal: '$a')"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

assert_contains() {
        local desc="$1" haystack="$2" needle="$3"
        if [[ "$haystack" == *"$needle"* ]]; then
                echo "    [OK] $desc"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc"
                echo "        haystack: $haystack"
                echo "        needle not found: $needle"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

assert_file_exists() {
        local desc="$1" path="$2"
        if [ -f "$path" ]; then
                echo "    [OK] $desc (file exists: $path)"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc (file missing: $path)"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

assert_file_not_exists() {
        local desc="$1" path="$2"
        if [ ! -f "$path" ]; then
                echo "    [OK] $desc (file correctly absent: $path)"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc (file should be gone: $path)"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

assert_rc() {
        local desc="$1" expected_rc="$2" actual_rc="$3"
        if [ "$actual_rc" = "$expected_rc" ]; then
                echo "    [OK] $desc (exit code $actual_rc)"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] $desc"
                echo "        expected exit: $expected_rc"
                echo "        actual exit:   $actual_rc"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("$desc")
        fi
}

# ---- Setup / teardown -------------------------------------------------------

setup_cache_dir() {
        local d
        d=$(mktemp -d -t morphe-cache-test-XXXXXX)
        echo "$d"
}

teardown_cache_dir() {
        local d="$1"
        rm -rf "$d"
}

# Make a fake but valid ZIP-shaped file (so verify_jar passes if called)
make_fake_zip() {
        local path="$1"
        python3 -c "
import zipfile
with zipfile.ZipFile('$path', 'w') as zf:
    zf.writestr('dummy.txt', 'mock')
    zf.writestr('extensions/shared.dex', 'mock')
"
}

# Compute the actual sha256 of a file we just made
sha_of() {
        sha256sum "$1" | awk '{print $1}'
}

# Build a deterministic identity for testing, bypassing the GitHub API.
# Args: artifact_name source_repo tag commit_sha checksum size platform arch bp_hash
make_identity() {
        local artifact="$1" repo="$2" tag="$3" sha="$4" checksum="$5" size="$6" platform="$7" arch="$8" bp="$9"
        echo "artifact_name=${artifact} source_repo=${repo} tag=${tag} commit_sha=${sha} checksum=${checksum} size=${size} platform=${platform} arch=${arch} build_params_hash=${bp}"
}

# Source the cache library with an isolated CACHE_DIR
load_cache_lib() {
        local test_dir="$1"
        CACHE_DIR="$test_dir"
        CACHE_LOCK_TIMEOUT=10
        CACHE_RETENTION_COUNT=2
        CACHE_RETENTION_AGE_DAYS=0
        CACHE_FALLBACK_ALLOWED=true
        CACHE_FALLBACK_STATUS="stale"
        # Resolve script dir relative to this test file
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        # shellcheck disable=SC1090
        source "${script_dir}/cache.sh"
        # Re-assert the test cache dir (cache.sh's defaults may have overridden)
        CACHE_DIR="$test_dir"
        export CACHE_DIR
}

# ---- Tests ------------------------------------------------------------------

test_1() {
        echo "=== Test 1: cache key contains all identity components ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        local id; id=$(make_identity \
                "morphe-desktop-1.16.0-all.jar" \
                "MorpheApp/morphe-desktop" \
                "v1.16.0" \
                "abc12345" \
                "deadbeef" \
                44512111 \
                "linux" \
                "x86_64" \
                "aabbccdd")
        local key; key=$(cache_compute_key "$id")
        assert_contains "key has repo"     "$key" "MorpheApp-morphe-desktop"
        assert_contains "key has tag"      "$key" "v1.16.0"
        assert_contains "key has commit"   "$key" "abc12345"
        assert_contains "key has checksum" "$key" "deadbeef"
        assert_contains "key has platform" "$key" "linux"
        assert_contains "key has arch"     "$key" "x86_64"
        assert_contains "key has bp hash"  "$key" "aabbccdd"
        teardown_cache_dir "$td"
}

test_1b() {
        echo "=== Test 1b: any identity change yields a different key ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"

        local id_a id_b key_a key_b
        id_a=$(make_identity "morphe-desktop-1.16.0-all.jar" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" "deadbeef" 44512111 linux x86_64 aabbccdd)
        id_b=$(make_identity "morphe-desktop-1.16.1-all.jar" "MorpheApp/morphe-desktop" "v1.16.1" "abc12345" "deadbeef" 44512111 linux x86_64 aabbccdd)
        key_a=$(cache_compute_key "$id_a")
        key_b=$(cache_compute_key "$id_b")
        assert_ne "different tag => different key" "$key_a" "$key_b"

        local id_c key_c
        id_c=$(make_identity "morphe-desktop-1.16.0-all.jar" "MorpheApp/morphe-desktop" "v1.16.0" "ffff9999" "deadbeef" 44512111 linux x86_64 aabbccdd)
        key_c=$(cache_compute_key "$id_c")
        assert_ne "different commit_sha => different key" "$key_a" "$key_c"

        local id_d key_d
        id_d=$(make_identity "morphe-desktop-1.16.0-all.jar" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" "cafef00d" 44512111 linux x86_64 aabbccdd)
        key_d=$(cache_compute_key "$id_d")
        assert_ne "different checksum => different key" "$key_a" "$key_d"

        local key_a_again
        key_a_again=$(cache_compute_key "$id_a")
        assert_eq "same identity => same key (determinism)" "$key_a" "$key_a_again"

        teardown_cache_dir "$td"
}

test_1c() {
        echo "=== Test 1c: cache validation must NOT pass on filename alone ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        make_fake_zip "$td/morphe-desktop-1.16.0-all.jar"

        local id; id=$(make_identity \
                "morphe-desktop-1.16.0-all.jar" \
                "MorpheApp/morphe-desktop" \
                "v1.16.0" \
                "abc12345" \
                "" \
                44512111 \
                linux x86_64 aabbccdd)

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup returns 1 when .meta missing" 1 "$rc"
        assert_contains "reason mentions meta" "$out" "meta_missing_or_corrupt"

        teardown_cache_dir "$td"
}

test_2() {
        echo "=== Test 2: cache hit on valid artifact ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_2.jar"
        make_fake_zip "$src"
        local actual_sha; actual_sha=$(sha_of "$src")

        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)

        cache_store "$id" "$src" >/dev/null 2>&1

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup returns 0 (hit)" 0 "$rc"
        assert_contains "log says decision=hit" "$out" "decision=hit"
        assert_contains "path returned" "$out" "$artifact"

        teardown_cache_dir "$td"
}

test_3() {
        echo "=== Test 3: cache miss when cache empty ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local id; id=$(make_identity \
                "morphe-desktop-1.16.0-all.jar" \
                "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "" 0 linux x86_64 aabbccdd)

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup returns 1 (miss)" 1 "$rc"
        assert_contains "log says decision=miss" "$out" "decision=miss"
        assert_contains "reason is file_not_found" "$out" "file_not_found"

        teardown_cache_dir "$td"
}

test_4() {
        echo "=== Test 4: version change invalidates old cache ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local old="morphe-desktop-1.14.0-all.jar"
        local new="morphe-desktop-1.16.0-all.jar"
        local src_old="${td}/src_old.jar"
        make_fake_zip "$src_old"
        local old_sha; old_sha=$(sha_of "$src_old")

        local id_old; id_old=$(make_identity \
                "$old" "MorpheApp/morphe-desktop" "v1.14.0" "old12345" \
                "$old_sha" $(stat -c %s "$src_old") linux x86_64 aabbccdd)
        cache_store "$id_old" "$src_old" >/dev/null 2>&1

        local id_new; id_new=$(make_identity \
                "$new" "MorpheApp/morphe-desktop" "v1.16.0" "new12345" \
                "" 0 linux x86_64 aabbccdd)

        local out rc
        out=$(cache_lookup "$id_new" 2>&1); rc=$?
        assert_rc "lookup for new version returns 1 (miss)" 1 "$rc"
        assert_contains "log says decision=miss" "$out" "decision=miss"

        cache_purge_stale "$id_new" >/dev/null 2>&1
        local old_status
        old_status=$(_cache_meta_field "$old" status 2>/dev/null)
        assert_eq "old artifact status is stale" "$old_status" "stale"

        teardown_cache_dir "$td"
}

test_5() {
        echo "=== Test 5: source change with same name → reject ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_5.jar"
        make_fake_zip "$src"
        local actual_sha; actual_sha=$(sha_of "$src")

        local id_a; id_a=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "aaaa1111" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id_a" "$src" >/dev/null 2>&1

        local id_b; id_b=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "bbbb2222" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)

        local out rc
        out=$(cache_lookup "$id_b" 2>&1); rc=$?
        assert_rc "lookup with mismatched commit_sha returns 1" 1 "$rc"
        assert_contains "reason mentions commit_sha_mismatch" "$out" "commit_sha_mismatch"

        teardown_cache_dir "$td"
}

test_6() {
        echo "=== Test 6: checksum mismatch → reject + clean + clear error ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_6.jar"
        make_fake_zip "$src"
        local actual_sha; actual_sha=$(sha_of "$src")

        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id" "$src" >/dev/null 2>&1

        # Tamper with the cached file (so actual checksum no longer matches)
        # Tamper with the cached file IN-PLACE (overwrite first byte, size unchanged)
        # so that ONLY the checksum differs — not the size.
        dd if=/dev/zero of="$td/$artifact" bs=1 count=1 conv=notrunc 2>/dev/null

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup returns 1 after tampering" 1 "$rc"
        assert_contains "reason mentions checksum_mismatch" "$out" "checksum_mismatch"
        assert_contains "error shows expected checksum" "$out" "expected=$actual_sha"

        local status
        status=$(_cache_meta_field "$artifact" status)
        assert_eq "artifact marked invalid" "$status" "invalid"

        teardown_cache_dir "$td"
}

test_7() {
        echo "=== Test 7: metadata mismatch → reject + clear reason ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_7.jar"
        make_fake_zip "$src"
        local actual_sha; actual_sha=$(sha_of "$src")

        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id" "$src" >/dev/null 2>&1

        # Platform mismatch
        local id_wrong_plat; id_wrong_plat=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" 250 "windows" x86_64 aabbccdd)
        local out rc
        out=$(cache_lookup "$id_wrong_plat" 2>&1); rc=$?
        assert_rc "platform mismatch returns 1" 1 "$rc"
        assert_contains "reason mentions platform_mismatch" "$out" "platform_mismatch"

        # Arch mismatch
        local id_wrong_arch; id_wrong_arch=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux arm64 aabbccdd)
        out=$(cache_lookup "$id_wrong_arch" 2>&1); rc=$?
        assert_rc "arch mismatch returns 1" 1 "$rc"
        assert_contains "reason mentions arch_mismatch" "$out" "arch_mismatch"

        # Build params mismatch
        local id_wrong_bp; id_wrong_bp=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 "ffffff")
        out=$(cache_lookup "$id_wrong_bp" 2>&1); rc=$?
        assert_rc "build_params mismatch returns 1" 1 "$rc"
        assert_contains "reason mentions build_params_hash_mismatch" "$out" "build_params_hash_mismatch"

        teardown_cache_dir "$td"
}

test_8() {
        echo "=== Test 8: download failure → no partial cache ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "" 0 linux x86_64 aabbccdd)
        local bad_url="http://127.0.0.1:9/no-such-file"

        local out rc
        out=$(cache_get "$id" "$bad_url" 2>&1); rc=$?
        assert_rc "cache_get returns 1 on download failure" 1 "$rc"
        assert_contains "log mentions download_failed" "$out" "download_failed"

        assert_file_not_exists "no partial .jar in cache" "$td/$artifact"
        assert_file_not_exists "no .tmp file leaked"      "$td/$artifact.tmp"

        teardown_cache_dir "$td"
}

test_9() {
        echo "=== Test 9a: fallback ALLOWED uses old cache on download fail ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"
        CACHE_FALLBACK_ALLOWED=true

        local old="morphe-desktop-1.14.0-all.jar"
        local src_old="${td}/src_9_old.jar"
        make_fake_zip "$src_old"
        local old_sha; old_sha=$(sha_of "$src_old")
        local id_old; id_old=$(make_identity \
                "$old" "MorpheApp/morphe-desktop" "v1.14.0" "old12345" \
                "$old_sha" $(stat -c %s "$src_old") linux x86_64 aabbccdd)
        cache_store "$id_old" "$src_old" >/dev/null 2>&1
        _cache_set_status "$old" "stale" "test_setup" >/dev/null

        local new="morphe-desktop-1.16.0-all.jar"
        local id_new; id_new=$(make_identity \
                "$new" "MorpheApp/morphe-desktop" "v1.16.0" "new12345" \
                "" 0 linux x86_64 aabbccdd)
        local bad_url="http://127.0.0.1:9/no-such-file"

        local out rc
        out=$(cache_get "$id_new" "$bad_url" 2>&1); rc=$?
        assert_rc "fallback returns 0 when allowed" 0 "$rc"
        assert_contains "log says decision=fallback" "$out" "decision=fallback"
        assert_contains "fallback path is the old artifact" "$out" "$old"

        teardown_cache_dir "$td"

        echo "=== Test 9b: fallback DENIED fails on download fail ==="
        td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"
        CACHE_FALLBACK_ALLOWED=false

        local src_old2="${td}/src_9b.jar"
        make_fake_zip "$src_old2"
        local id_old2; id_old2=$(make_identity \
                "$old" "MorpheApp/morphe-desktop" "v1.14.0" "old12345" \
                "$(sha_of "$src_old2")" $(stat -c %s "$src_old2") linux x86_64 aabbccdd)
        cache_store "$id_old2" "$src_old2" >/dev/null 2>&1
        _cache_set_status "$old" "stale" "test_setup" >/dev/null

        out=$(cache_get "$id_new" "$bad_url" 2>&1); rc=$?
        assert_rc "fallback denied returns 1" 1 "$rc"
        assert_contains "log says fallback_denied" "$out" "fallback_denied"

        teardown_cache_dir "$td"
}

test_10() {
        echo "=== Test 10: store writes .meta + index atomically ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_10.jar"
        make_fake_zip "$src"
        local actual_sha; actual_sha=$(sha_of "$src")
        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$actual_sha" $(stat -c %s "$src") linux x86_64 aabbccdd)

        local out rc
        out=$(cache_store "$id" "$src" 2>&1); rc=$?
        assert_rc "store returns 0" 0 "$rc"

        assert_file_exists ".meta sidecar exists" "$td/$artifact.meta"
        local meta_json; meta_json=$(cat "$td/$artifact.meta")
        assert_contains "meta has artifact_name"    "$meta_json" "morphe-desktop-1.16.0-all.jar"
        assert_contains "meta has source_repo"      "$meta_json" "MorpheApp/morphe-desktop"
        assert_contains "meta has tag"              "$meta_json" "v1.16.0"
        assert_contains "meta has commit_sha"       "$meta_json" "abc12345"
        assert_contains "meta has checksum"         "$meta_json" "$actual_sha"
        assert_contains "meta has platform"         "$meta_json" "linux"
        assert_contains "meta has arch"             "$meta_json" "x86_64"
        assert_contains "meta has build_params_hash" "$meta_json" "aabbccdd"
        assert_contains "meta has status valid"    "$meta_json" '"valid"'

        assert_file_exists "index.json exists" "$td/index.json"
        local idx; idx=$(cat "$td/index.json")
        assert_contains "index has artifact entry" "$idx" "$artifact"
        assert_contains "index marks it valid"      "$idx" '"valid"'

        teardown_cache_dir "$td"
}

test_10b() {
        echo "=== Test 10b: corrupt .meta is rejected on lookup ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        make_fake_zip "$td/$artifact"
        echo "{not valid json" > "$td/$artifact.meta"

        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "" 0 linux x86_64 aabbccdd)

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup returns 1 on corrupt .meta" 1 "$rc"
        assert_contains "reason mentions meta_missing_or_corrupt" "$out" "meta_missing_or_corrupt"

        teardown_cache_dir "$td"
}

test_11() {
        echo "=== Test 11: retention deletes oldest beyond limit ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"
        CACHE_RETENTION_COUNT=2

        local i=0
        for ver in 1.10.0 1.11.0 1.12.0 1.13.0; do
                local fn="morphe-desktop-${ver}-all.jar"
                local s="${td}/src_${ver}.jar"
                make_fake_zip "$s"
                local id_v; id_v=$(make_identity \
                        "$fn" "MorpheApp/morphe-desktop" "v${ver}" "sha${ver}" \
                        "$(sha_of "$s")" $(stat -c %s "$s") linux x86_64 "bp${ver}")
                cache_store "$id_v" "$s" >/dev/null 2>&1
                # Backdate .meta created_at so older versions sort first
                local past
                past=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=30-$i)).isoformat())")
                jq --arg t "$past" '.created_at=$t' "$td/$fn.meta" > "${td}/${fn}.meta.tmp" && mv "${td}/${fn}.meta.tmp" "$td/$fn.meta"
                i=$((i + 1))
        done

        local new="morphe-desktop-1.14.0-all.jar"
        local src_new="${td}/src_11_new.jar"
        make_fake_zip "$src_new"
        local id_new; id_new=$(make_identity \
                "$new" "MorpheApp/morphe-desktop" "v1.14.0" "new12345" \
                "$(sha_of "$src_new")" $(stat -c %s "$src_new") linux x86_64 aabbccdd)
        cache_store "$id_new" "$src_new" >/dev/null 2>&1
        cache_purge_stale "$id_new" >/dev/null 2>&1

        local remaining
        remaining=$(find "$td" -maxdepth 1 -name 'morphe-desktop-*.jar' | wc -l)
        assert_eq "remaining artifact count = retention_limit + 1 (new)" "$remaining" "3"

        assert_file_not_exists "1.10.0 deleted (oldest)" "$td/morphe-desktop-1.10.0-all.jar"
        assert_file_not_exists "1.11.0 deleted (2nd oldest)" "$td/morphe-desktop-1.11.0-all.jar"
        assert_file_exists "1.12.0 kept (within retention)" "$td/morphe-desktop-1.12.0-all.jar"
        assert_file_exists "1.13.0 kept (within retention)" "$td/morphe-desktop-1.13.0-all.jar"
        assert_file_exists "1.14.0 kept (new/valid)"        "$td/morphe-desktop-1.14.0-all.jar"

        teardown_cache_dir "$td"
}

test_12() {
        echo "=== Test 12: active version selected by identity, not mtime ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local v1="morphe-desktop-1.14.0-all.jar"
        local v2="morphe-desktop-1.16.0-all.jar"
        local src_v1="${td}/src_12_v1.jar"
        local src_v2="${td}/src_12_v2.jar"
        make_fake_zip "$src_v1"
        make_fake_zip "$src_v2"
        # Make v1 NEWER (in mtime) than v2 — to test that we don't pick by mtime
        touch -t 203801010000 "$src_v1"
        touch -t 200001010000 "$src_v2"

        local id_v1; id_v1=$(make_identity "$v1" "MorpheApp/morphe-desktop" "v1.14.0" "sha1" "$(sha_of "$src_v1")" $(stat -c %s "$src_v1") linux x86_64 aabbccdd)
        local id_v2; id_v2=$(make_identity "$v2" "MorpheApp/morphe-desktop" "v1.16.0" "sha2" "$(sha_of "$src_v2")" $(stat -c %s "$src_v2") linux x86_64 aabbccdd)
        cache_store "$id_v1" "$src_v1" >/dev/null 2>&1
        cache_store "$id_v2" "$src_v2" >/dev/null 2>&1

        local out rc
        out=$(cache_lookup "$id_v2" 2>&1); rc=$?
        assert_rc "lookup returns 0 for v2 (identity match)" 0 "$rc"
        assert_contains "returned path is v2 (NOT v1, despite mtime)" "$out" "$v2"
        assert_contains "log says decision=hit" "$out" "decision=hit"

        teardown_cache_dir "$td"
}

test_12b() {
        echo "=== Test 12b: lookup fails clearly when identity is inconsistent ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        make_fake_zip "$td/$artifact"

        cat > "$td/$artifact.meta" << 'META'
{"artifact_name":"morphe-desktop-1.16.0-all.jar","source_repo":"","tag":"","commit_sha":"","checksum":"","size":0,"platform":"","arch":"","build_params_hash":"","created_at":"","status":"valid"}
META

        local id; id=$(make_identity "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" "" 0 linux x86_64 aabbccdd)
        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "lookup fails on identity mismatch" 1 "$rc"

        teardown_cache_dir "$td"
}

test_13() {
        echo "=== Test 13: concurrent same-version updates don't corrupt ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"

        local srcs=()
        for i in 1 2 3 4; do
                local s="${td}/src_13_${i}.jar"
                make_fake_zip "$s"
                echo "variant $i" >> "$s"
                srcs+=("$s")
        done

        local pids=()
        for i in 0 1 2 3; do
                local s="${srcs[$i]}"
                local id_v; id_v=$(make_identity \
                        "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                        "$(sha_of "$s")" "$(stat -c %s "$s")" linux x86_64 aabbccdd)
                ( cache_store "$id_v" "$s" >/dev/null 2>&1 ) &
                pids+=($!)
        done
        for p in "${pids[@]}"; do wait "$p"; done

        assert_file_exists "artifact file exists after parallel writes" "$td/$artifact"
        assert_file_exists ".meta exists after parallel writes"           "$td/$artifact.meta"

        jq -e '.' "$td/$artifact.meta" >/dev/null 2>&1
        assert_rc ".meta is valid JSON" 0 "$?"

        teardown_cache_dir "$td"
}

test_14() {
        echo "=== Test 14: concurrent different-version updates don't cross-contaminate ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local v1="morphe-desktop-1.14.0-all.jar"
        local v2="morphe-desktop-1.16.0-all.jar"
        local src_v1="${td}/src_14_v1.jar"
        local src_v2="${td}/src_14_v2.jar"
        make_fake_zip "$src_v1"
        make_fake_zip "$src_v2"
        local id_v1; id_v1=$(make_identity "$v1" "MorpheApp/morphe-desktop" "v1.14.0" "sha1" "$(sha_of "$src_v1")" $(stat -c %s "$src_v1") linux x86_64 aabbccdd)
        local id_v2; id_v2=$(make_identity "$v2" "MorpheApp/morphe-desktop" "v1.16.0" "sha2" "$(sha_of "$src_v2")" $(stat -c %s "$src_v2") linux x86_64 aabbccdd)

        ( cache_store "$id_v1" "$src_v1" >/dev/null 2>&1 ) &
        local p1=$!
        ( cache_store "$id_v2" "$src_v2" >/dev/null 2>&1 ) &
        local p2=$!
        wait "$p1"; wait "$p2"

        assert_file_exists "v1 file exists" "$td/$v1"
        assert_file_exists "v2 file exists" "$td/$v2"
        assert_file_exists "v1 .meta exists" "$td/$v1.meta"
        assert_file_exists "v2 .meta exists" "$td/$v2.meta"

        local out1 out2
        out1=$(cache_lookup "$id_v1" 2>/dev/null)
        out2=$(cache_lookup "$id_v2" 2>/dev/null)
        assert_contains "lookup v1 returns v1" "$out1" "$v1"
        assert_contains "lookup v2 returns v2" "$out2" "$v2"

        teardown_cache_dir "$td"
}

test_15() {
        echo "=== Test 15: failed store leaves no partial valid cache ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "wrongchecksum" 999 linux x86_64 aabbccdd)

        local rc
        cache_store "$id" "/nonexistent/source.jar" >/dev/null 2>&1 || rc=$?
        assert_rc "store returns 1 when src missing" 1 "${rc:-0}"

        # No .meta should be present (or if it is, status != valid)
        if [ -f "$td/$artifact.meta" ]; then
                local s; s=$(_cache_meta_field "$artifact" status 2>/dev/null)
                [ "$s" != "valid" ] && assert_eq ".meta status not valid" "$s" "invalid_or_missing"
        fi

        local out rcl
        out=$(cache_lookup "$id" 2>&1); rcl=$?
        assert_rc "lookup returns 1 after failed store" 1 "$rcl"

        teardown_cache_dir "$td"
}

test_16() {
        echo "=== Test 16a: subsequent workflow gets cache hit on valid artifact ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_16.jar"
        make_fake_zip "$src"
        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$(sha_of "$src")" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id" "$src" >/dev/null 2>&1

        local out rc
        out=$(cache_lookup "$id" 2>&1); rc=$?
        assert_rc "second workflow gets cache hit" 0 "$rc"
        assert_contains "log says decision=hit" "$out" "decision=hit"

        teardown_cache_dir "$td"

        echo "=== Test 16b: identity change invalidates cache ==="
        td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        # Re-create src file (the previous td was torn down, so $src from 16a is gone)
        src="${td}/src_16b.jar"
        make_fake_zip "$src"
        # Re-derive id with the new src's checksum (we want the cached copy to be VALID
        # so that looking it up with a different checksum triggers a checksum_mismatch)
        id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$(sha_of "$src")" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id" "$src" >/dev/null 2>&1

        local id_changed; id_changed=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" \
                0 linux x86_64 aabbccdd)

        out=$(cache_lookup "$id_changed" 2>&1); rc=$?
        assert_rc "lookup with changed checksum returns 1" 1 "$rc"
        assert_contains "reason is checksum_mismatch" "$out" "checksum_mismatch"

        teardown_cache_dir "$td"
}

test_17() {
        echo "=== Test 17a: cache decision is logged with all relevant fields ==="
        local td; td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"

        local artifact="morphe-desktop-1.16.0-all.jar"
        local src="${td}/src_17.jar"
        make_fake_zip "$src"
        local id; id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$(sha_of "$src")" $(stat -c %s "$src") linux x86_64 aabbccdd)

        local log_out
        log_out=$(cache_store "$id" "$src" 2>&1)
        assert_contains "log has operation=store"     "$log_out" "operation=store"
        assert_contains "log has status=ok"            "$log_out" "status=ok"
        assert_contains "log has artifact="            "$log_out" "artifact=$artifact"
        assert_contains "log has tag="                 "$log_out" "tag=v1.16.0"

        log_out=$(cache_lookup "$id" 2>&1)
        assert_contains "lookup log has decision=hit"  "$log_out" "decision=hit"
        assert_contains "lookup log has tag"           "$log_out" "tag=v1.16.0"

        teardown_cache_dir "$td"

        echo "=== Test 17b: same input → same decision (determinism) ==="
        td=$(setup_cache_dir); load_cache_lib "$td"
        mkdir -p "$td"
        # Re-create src and re-derive id (previous td was torn down)
        src="${td}/src_17b.jar"
        make_fake_zip "$src"
        id=$(make_identity \
                "$artifact" "MorpheApp/morphe-desktop" "v1.16.0" "abc12345" \
                "$(sha_of "$src")" $(stat -c %s "$src") linux x86_64 aabbccdd)
        cache_store "$id" "$src" >/dev/null 2>&1

        local r1 r2
        r1=$(cache_lookup "$id" 2>&1 | grep -oE 'decision=[a-z]+')
        r2=$(cache_lookup "$id" 2>&1 | grep -oE 'decision=[a-z]+')
        assert_eq "two lookups produce same decision" "$r1" "$r2"

        teardown_cache_dir "$td"
}

# ---- Main runner -----------------------------------------------------------

test_18() {
        echo "=== Test 18: utils.sh downloader API + pre-flight syntax regression ==="
        # Catches bugs from runs #35461177312 (cache.sh syntax) and #35483920837
        # (missing downloader functions) and #35484821460 (pre-flight wrong options).
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        local utils_file="${script_dir}/utils.sh"
        [ -f "$utils_file" ] || {
                echo "    [FAIL] utils.sh not found at $utils_file"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("utils.sh downloader API - file missing")
                return
        }

        # bash -n syntax check FIRST
        bash -n "$utils_file" 2>/dev/null
        if [ $? -ne 0 ]; then
                echo "    [FAIL] bash -n utils.sh failed (syntax error)"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("utils.sh syntax error")
                return
        fi
        echo "    [OK] bash -n utils.sh: syntax OK"
        PASS=$((PASS + 1))

        # Check each required downloader function is DEFINED in utils.sh
        local required_fns=(
                get_archive_resp get_archive_pkg_name get_archive_vers dl_archive
                get_apkmirror_resp get_apkmirror_pkg_name get_apkmirror_vers dl_apkmirror
                get_uptodown_resp get_uptodown_pkg_name get_uptodown_vers dl_uptodown
                get_direct_resp get_direct_pkg_name get_direct_vers dl_direct
        )
        for fn in "${required_fns[@]}"; do
                if grep -qE "^${fn}\s*\(\)" "$utils_file"; then
                        echo "    [OK] $fn defined"
                        PASS=$((PASS + 1))
                else
                        echo "    [FAIL] $fn NOT defined in utils.sh"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("$fn missing from utils.sh")
                fi
        done

        # Verify the pre-flight probe uses morphe-desktop 1.16.0 syntax:
        #   --patches (not -p)
        #   -f (not --filter-package-name)
        #   --with-versions --with-packages (not --versions --packages)
        #   NO -b flag
        local pf_line
        pf_line=$(grep 'list-patches.*com.google.android.youtube' "$utils_file" | head -1)
        if [ -z "$pf_line" ]; then
                echo "    [FAIL] pre-flight probe line not found in utils.sh"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("pre-flight probe line missing")
        else
                echo "    pre-flight line: $pf_line"
                PASS=$((PASS + 1))
                # Check --patches (not -p at start of option)
                if echo "$pf_line" | grep -q -- '--patches "\$patches_jar"'; then
                        echo "    [OK] uses --patches (not -p)"
                        PASS=$((PASS + 1))
                else
                        echo "    [FAIL] does not use --patches"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("pre-flight uses -p instead of --patches")
                fi
                # Check -f (morphe-desktop short option for --filter-package-name)
                if echo "$pf_line" | grep -q -- '-f "com.google.android.youtube"'; then
                        echo "    [OK] uses -f (morphe-desktop syntax)"
                        PASS=$((PASS + 1))
                else
                        echo "    [FAIL] does not use -f"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("pre-flight uses --filter-package-name instead of -f")
                fi
                # Check --with-versions --with-packages
                if echo "$pf_line" | grep -q -- '--with-versions --with-packages'; then
                        echo "    [OK] uses --with-versions --with-packages"
                        PASS=$((PASS + 1))
                else
                        echo "    [FAIL] does not use --with-versions --with-packages"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("pre-flight uses --versions --packages (unsupported)")
                fi
                # Check NO -b flag
                if echo "$pf_line" | grep -qE ' -b([[:space:]]|$)'; then
                        echo "    [FAIL] still has -b flag"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("pre-flight has -b flag")
                else
                        echo "    [OK] no -b flag"
                        PASS=$((PASS + 1))
                fi
        fi

        # Verify ipr() and okr() write to STDERR (not STDOUT)
        # This catches the bug from run #35484821460 where PREBUILTS=$(get_prebuilts ...)
        # was polluted with log lines, corrupting $patches_jar and $cli_jar.
        if grep -A5 "^ipr() {" "$utils_file" | grep -q '>&2'; then
                echo "    [OK] ipr() writes to stderr (stdout stays clean)"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] ipr() writes to stdout (pollutes captured stdout)"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("ipr() writes to stdout (should be stderr)")
        fi
        if grep -E '^okr\(\)' "$utils_file" | grep -q '>&2'; then
                echo "    [OK] okr() writes to stderr"
                PASS=$((PASS + 1))
        else
                echo "    [FAIL] okr() writes to stdout"
                FAIL=$((FAIL + 1))
                FAILED_TESTS+=("okr() writes to stdout (should be stderr)")
        fi

        # Verify cache integration is preserved
        for cache_fn in cache_resolve_identity cache_get; do
                if grep -q "\b${cache_fn}\b" "$utils_file"; then
                        echo "    [OK] $cache_fn still referenced (cache integration preserved)"
                        PASS=$((PASS + 1))
                else
                        echo "    [FAIL] $cache_fn not referenced (cache integration LOST)"
                        FAIL=$((FAIL + 1))
                        FAILED_TESTS+=("$cache_fn missing from utils.sh")
                fi
        done
}

run_one() {
        local n="$1"
        local fn="test_${n}"
        if type "$fn" &>/dev/null; then
                echo
                echo "---------- Scenario $n ----------"
                "$fn"
        else
                echo "Test $n not found."
        fi
}

if [ $# -gt 0 ]; then
        for n in "$@"; do
                run_one "$n"
        done
else
        for n in 1 1b 1c 2 3 4 5 6 7 8 9 10 10b 11 12 12b 13 14 15 16 17 18; do
                run_one "$n"
        done
fi

echo
echo "==============================================="
echo "  Results: PASS=$PASS  FAIL=$FAIL"
echo "==============================================="
if [ $FAIL -gt 0 ]; then
        echo
        echo "Failed tests:"
        for t in "${FAILED_TESTS[@]}"; do
                echo "  - $t"
        done
        exit 1
fi
exit 0
