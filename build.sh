#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
version_file="$root/versions/pc-v0.0.247-f3437be-260710.json"
game_dir="${DELTARUNE_GAME_DIR:-}"
output_dir="$root/output"
patchset_dir=""
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dr-tas-chs"
work_base="${TMPDIR:-/tmp}"
offline=0
keep_work=0
run_dir=""
staging_dir=""
staging_identity=""
previous_output=""
download_lock=""
download_lock_owned=0
output_lock=""
output_lock_owned=0
patchset_lock=""
patchset_lock_fd=""
patchset_staging=""
patchset_staging_identity=""
patchset_reservation=""
previous_patchset=""
output_publish_reservation=""
new_output_published=0
new_patchset_published=0
publish_committed=0

usage() {
    cat <<'EOF'
Usage: ./build.sh --game-dir DIR [options]

Build Keucher Mod + DeltaruneChinese locally from one clean DELTARUNE install.
The game directory is read-only; verified output is written to ./output by default.

Options:
  --game-dir DIR    Clean DELTARUNE v0.0.247 directory (required)
  --output-dir DIR  Final output directory (default: ./output)
  --patchset-dir DIR
                    Also create a complete local BPS patchset
  --cache-dir DIR   Download, NuGet, and Wine cache
  --work-dir DIR    Parent directory for the temporary build workspace
  --offline         Use only cached downloads and NuGet packages
  --keep-work       Keep the temporary build workspace after success
  -h, --help        Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

note() {
    printf '\n==> %s\n' "$*"
}

while (($#)); do
    case "$1" in
        --game-dir)
            (($# >= 2)) || die "--game-dir requires a path"
            game_dir=$2
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a path"
            output_dir=$2
            shift 2
            ;;
        --cache-dir)
            (($# >= 2)) || die "--cache-dir requires a path"
            cache_dir=$2
            shift 2
            ;;
        --patchset-dir)
            (($# >= 2)) || die "--patchset-dir requires a path"
            patchset_dir=$2
            shift 2
            ;;
        --work-dir)
            (($# >= 2)) || die "--work-dir requires a path"
            work_base=$2
            shift 2
            ;;
        --offline)
            offline=1
            shift
            ;;
        --keep-work)
            keep_work=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$game_dir" ]] || { usage >&2; exit 2; }
[[ -f "$version_file" ]] || die "version lock is missing: $version_file"

for path_entry in "$game_dir" "$output_dir" "$cache_dir" "$work_base"; do
    [[ ! -L "$path_entry" ]] || die "path arguments may not be symbolic links: $path_entry"
done
if [[ -n "$patchset_dir" ]]; then
    [[ ! -L "$patchset_dir" ]] || die "path arguments may not be symbolic links: $patchset_dir"
fi

for command in awk chmod cmp cp curl df diff dotnet ffmpeg ffprobe find findmnt flock fpcalc gawk git id jq mktemp patch perl readlink rg sha256sum sort stat tar unzip wine; do
    command -v "$command" >/dev/null || die "missing dependency: $command"
done

dotnet_major="$(dotnet --version | cut -d. -f1)"
[[ "$dotnet_major" =~ ^[0-9]+$ ]] && ((dotnet_major >= 10)) ||
    die ".NET SDK 10 or newer is required (found: $(dotnet --version))"

[[ -d "$game_dir" ]] || die "game directory does not exist: $game_dir"
game_dir="$(readlink -f -- "$game_dir")"
output_dir="$(readlink -m -- "$output_dir")"
if [[ -n "$patchset_dir" ]]; then
    patchset_dir="$(readlink -m -- "$patchset_dir")"
fi
cache_dir="$(readlink -m -- "$cache_dir")"
work_base="$(readlink -m -- "$work_base")"
output_parent="$(dirname -- "$output_dir")"

paths_overlap() {
    local first=$1 second=$2
    [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

assert_no_mounts_below() {
    local path=$1 target mounts
    [[ -d "$path" && ! -L "$path" ]] || return 0
    mounts="$(findmnt -rn -o TARGET)" || die "could not enumerate mount points"
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if [[ "$target" == "$path" || "$target" == "$path/"* ]]; then
            die "refusing to replace a tree containing a mount point: $target"
        fi
    done <<<"$mounts"
}

remove_tree() {
    rm -rf --one-file-system -- "$1"
}

validate_patchset_lock_state() {
    local lock_file=$1 expected_uid=$2 expected_dir_identity=$3 fd=${4:-}
    local current_dir_identity path_identity fd_identity fd_path

    [[ -d "$patchset_lock" && ! -L "$patchset_lock" &&
        "$(readlink -f -- "$patchset_lock")" == "$patchset_lock" &&
        "$(stat -Lc %u -- "$patchset_lock")" == "$expected_uid" &&
        "$(stat -Lc %a -- "$patchset_lock")" == 700 ]] || return 1
    current_dir_identity="$(stat -Lc '%d:%i' -- "$patchset_lock")" || return 1
    [[ "$current_dir_identity" == "$expected_dir_identity" ]] || return 1
    [[ -f "$lock_file" && ! -L "$lock_file" &&
        "$(stat -Lc %u -- "$lock_file")" == "$expected_uid" &&
        "$(stat -Lc %a -- "$lock_file")" == 600 &&
        "$(stat -Lc %h -- "$lock_file")" -eq 1 &&
        "$(stat -Lc %s -- "$lock_file")" -eq 0 ]] || return 1
    if [[ -n "$fd" ]]; then
        fd_path="/proc/$$/fd/$fd"
        [[ -f "$fd_path" &&
            "$(stat -Lc %u -- "$fd_path")" == "$expected_uid" &&
            "$(stat -Lc %a -- "$fd_path")" == 600 &&
            "$(stat -Lc %h -- "$fd_path")" -eq 1 &&
            "$(stat -Lc %s -- "$fd_path")" -eq 0 ]] || return 1
        path_identity="$(stat -Lc '%d:%i' -- "$lock_file")" || return 1
        fd_identity="$(stat -Lc '%d:%i' -- "$fd_path")" || return 1
        [[ "$path_identity" == "$fd_identity" ]] || return 1
    fi
}

acquire_patchset_lock() {
    local parent=$1 name=$2 uid lock_file fd dir_identity unexpected
    uid="$(id -u)"
    patchset_lock="$parent/.dr-tas-chs-$name.lock"
    if ! mkdir -m 700 -- "$patchset_lock" 2>/dev/null; then
        [[ -d "$patchset_lock" && ! -L "$patchset_lock" ]] ||
            die "patchset lock is not a private directory: $patchset_lock"
    fi
    [[ "$(readlink -f -- "$patchset_lock")" == "$patchset_lock" &&
        "$(stat -Lc '%u:%a' -- "$patchset_lock")" == "$uid:700" ]] ||
        die "patchset lock directory has unsafe ownership or mode: $patchset_lock"
    dir_identity="$(stat -Lc '%d:%i' -- "$patchset_lock")"
    unexpected="$(find "$patchset_lock" -mindepth 1 -maxdepth 1 \
        ! -name publish.lock -print -quit)" || die "could not inspect patchset lock directory"
    [[ -z "$unexpected" ]] ||
        die "patchset lock directory contains an unexpected entry: $unexpected"
    lock_file="$patchset_lock/publish.lock"
    if [[ -e "$lock_file" || -L "$lock_file" ]]; then
        validate_patchset_lock_state "$lock_file" "$uid" "$dir_identity" ||
            die "patchset lock file has unsafe ownership, mode, type, or link count: $lock_file"
    else
        (umask 077; set -o noclobber; : >"$lock_file") 2>/dev/null || true
    fi
    exec {fd}<>"$lock_file"
    validate_patchset_lock_state "$lock_file" "$uid" "$dir_identity" "$fd" ||
        die "patchset lock file identity changed while it was opened: $lock_file"
    flock -n "$fd" || die "another build is using the patchset directory: $patchset_dir"
    validate_patchset_lock_state "$lock_file" "$uid" "$dir_identity" "$fd" ||
        die "patchset lock state changed after acquisition: $lock_file"
    patchset_lock_fd=$fd
}

path_contains() {
    local container=$1 path=$2
    [[ "$container" == "$path" || "$path" == "$container/"* ]]
}

require_safe_repo_write_path() {
    local path=$1 label=$2 rel
    path_contains "$path" "$root" &&
        die "$label may not equal or contain the repository: $path"
    if path_contains "$root" "$path"; then
        rel=${path#"$root"/}
        git -C "$root" check-ignore -q -- "$rel/.dr-tas-chs-write-probe" ||
            die "$label inside the repository must be gitignored: $path"
    fi
}

[[ "$output_dir" != "/" ]] || die "the output directory may not be /"
[[ -z "$patchset_dir" || "$patchset_dir" != "/" ]] || die "the patchset directory may not be /"
paths_overlap "$output_dir" "$game_dir" &&
    die "the output directory may not overlap the game directory"
require_safe_repo_write_path "$output_dir" "the output directory"
if [[ -n "$patchset_dir" ]]; then
    paths_overlap "$patchset_dir" "$game_dir" &&
        die "the patchset directory may not overlap the game directory"
    paths_overlap "$patchset_dir" "$output_dir" &&
        die "the patchset directory may not overlap the output directory"
    require_safe_repo_write_path "$patchset_dir" "the patchset directory"
fi
for write_dir in "$cache_dir" "$work_base"; do
    path_contains "$game_dir" "$write_dir" &&
        die "build working paths may not be inside the game directory: $write_dir"
    path_contains "$output_dir" "$write_dir" &&
        die "build working paths may not be inside the output directory: $write_dir"
    if [[ -n "$patchset_dir" ]]; then
        path_contains "$patchset_dir" "$write_dir" &&
            die "build working paths may not be inside the patchset directory: $write_dir"
    fi
    require_safe_repo_write_path "$write_dir" "build working paths"
done

case "$work_base" in
    *[!A-Za-z0-9_./-]*)
        die "the work path must contain only ASCII letters, digits, '_', '.', '/', or '-': $work_base"
        ;;
esac

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if ((publish_committed == 0)) && [[ -n "$previous_patchset" && -e "$previous_patchset" &&
        -n "$patchset_staging" && ! -e "$patchset_staging" && -e "$patchset_dir" ]]; then
        remove_tree "$patchset_dir"
        new_patchset_published=0
    fi
    if ((publish_committed == 0 && new_patchset_published)) && [[ -e "$patchset_dir" ]]; then
        remove_tree "$patchset_dir"
        new_patchset_published=0
    fi
    if ((publish_committed == 0)) && [[ -n "$previous_patchset" && -e "$previous_patchset" && ! -e "$patchset_dir" ]]; then
        if mv -T -- "$previous_patchset" "$patchset_dir"; then
            previous_patchset=""
            echo "restored the previous patchset after an interrupted publish" >&2
        else
            echo "error: could not restore previous patchset: $previous_patchset" >&2
        fi
    fi
    if ((publish_committed == 0)) && [[ -n "$previous_output" && -e "$previous_output" &&
        -n "$staging_dir" && ! -e "$staging_dir" && -e "$output_dir" ]]; then
        remove_tree "$output_dir"
        new_output_published=0
    fi
    if ((publish_committed == 0 && new_output_published)) && [[ -e "$output_dir" ]]; then
        remove_tree "$output_dir"
        new_output_published=0
    fi
    if [[ -n "$previous_output" && -e "$previous_output" && ! -e "$output_dir" ]]; then
        if mv -- "$previous_output" "$output_dir"; then
            previous_output=""
            echo "restored the previous output after an interrupted publish" >&2
        else
            echo "error: could not restore previous output: $previous_output" >&2
        fi
    fi
    if ((download_lock_owned)) && [[ -n "$download_lock" && -d "$download_lock" ]]; then
        rmdir -- "$download_lock" 2>/dev/null || true
    fi
    if [[ -n "$patchset_staging" && -e "$patchset_staging" ]]; then
        remove_tree "$patchset_staging"
    fi
    if [[ -z "$previous_patchset" && -n "$patchset_reservation" && -d "$patchset_reservation" && ! -L "$patchset_reservation" ]]; then
        remove_tree "$patchset_reservation"
    fi
    if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
        if ((keep_work)) && ((status != 0)); then
            echo "unpublished output kept at: $staging_dir" >&2
            staging_dir=""
        else
            remove_tree "$staging_dir"
        fi
    fi
    if [[ -n "$run_dir" && -d "$run_dir" ]]; then
        if ((status == 0 && keep_work == 0)); then
            remove_tree "$run_dir"
        else
            echo "build workspace kept at: $run_dir" >&2
        fi
    fi
    if ((output_lock_owned)) && [[ -d "$output_lock" ]]; then
        rmdir -- "$output_lock" 2>/dev/null || true
    fi
    if [[ -z "$previous_output" && -n "$output_publish_reservation" && -d "$output_publish_reservation" && ! -L "$output_publish_reservation" ]]; then
        remove_tree "$output_publish_reservation"
    fi
    [[ -z "$previous_output" ]] || echo "manual output recovery kept at: $previous_output" >&2
    [[ -z "$previous_patchset" ]] || echo "manual patchset recovery kept at: $previous_patchset" >&2
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sha() {
    sha256sum "$1" | awk '{print $1}'
}

verify_file() {
    local path=$1 expected_sha=$2 expected_bytes=${3:-}
    [[ -f "$path" && ! -L "$path" ]] || die "missing or unsafe regular file: $path"
    if [[ -n "$expected_bytes" ]]; then
        local actual_bytes
        actual_bytes="$(stat -c %s "$path")"
        [[ "$actual_bytes" == "$expected_bytes" ]] ||
            die "size mismatch: $path (expected $expected_bytes, got $actual_bytes)"
    fi
    local actual_sha
    actual_sha="$(sha "$path")"
    [[ "$actual_sha" == "$expected_sha" ]] ||
        die "SHA256 mismatch: $path (expected $expected_sha, got $actual_sha)"
}

validate_audio_file() {
    local path=$1 probe actual_duration
    probe="$(ffprobe -v error \
        -show_entries stream=codec_type,codec_name,sample_rate,channels \
        -show_entries format=duration -of json -- "$path")" ||
        die "could not inspect generated audio: $path"
    jq -e \
        --arg codec "$audio_codec" \
        --arg sample_rate "$audio_sample_rate" \
        --argjson channels "$audio_channels" '
        (.streams | length) == 1 and
        .streams[0].codec_type == "audio" and
        .streams[0].codec_name == $codec and
        .streams[0].sample_rate == $sample_rate and
        .streams[0].channels == $channels and
        (.format.duration | type == "string" and test("^[0-9]+([.][0-9]+)?$"))
    ' <<<"$probe" >/dev/null || die "generated audio properties do not match the version lock: $path"
    actual_duration="$(jq -er '.format.duration' <<<"$probe")" ||
        die "could not read generated audio duration: $path"
    awk -v actual="$actual_duration" -v expected="$audio_duration" '
        BEGIN {
            delta = actual - expected
            if (delta < 0) delta = -delta
            exit(delta > 0.001)
        }
    ' || die "generated audio duration does not match the version lock: $path"

    local fingerprint_output actual_fingerprint similarity
    fingerprint_output="$(fpcalc -raw -length "$audio_fingerprint_seconds" "$path")" ||
        die "could not calculate the audio fingerprint: $path"
    actual_fingerprint="$(awk -F= '$1 == "FINGERPRINT" {print substr($0, index($0, "=") + 1)}' \
        <<<"$fingerprint_output")"
    [[ "$actual_fingerprint" =~ ^[0-9]+(,[0-9]+)+$ ]] ||
        die "fpcalc returned an invalid fingerprint: $path"
    similarity="$(gawk \
        -v expected="$audio_fingerprint_raw" \
        -v actual="$actual_fingerprint" '
        function bit_count(value, count, i) {
            for (i = 0; i < 32; i++) {
                count += and(value, 1)
                value = rshift(value, 1)
            }
            return count
        }
        BEGIN {
            expected_count = split(expected, expected_values, ",")
            actual_count = split(actual, actual_values, ",")
            if (expected_count != actual_count || expected_count == 0) exit 2
            different_bits = 0
            for (i = 1; i <= expected_count; i++)
                different_bits += bit_count(xor(expected_values[i] + 0, actual_values[i] + 0))
            printf "%.9f", 1 - (different_bits / (expected_count * 32))
        }
    ')" || die "audio fingerprint length does not match the version lock: $path"
    awk -v actual="$similarity" -v minimum="$audio_fingerprint_min_similarity" \
        'BEGIN { exit(actual + 0 < minimum + 0) }' ||
        die "audio content fingerprint does not match the locked source: $path (similarity $similarity)"
}

validate_existing_output() {
    local dir=$1 build_info generated_audio_sha generated_audio_bytes
    local rel expected_bytes expected_sha first_audio=""

    [[ -d "$dir" && ! -L "$dir" ]] ||
        die "existing output is not a regular directory: $dir"
    assert_no_mounts_below "$dir"
    [[ -f "$dir/build-info.json" && ! -L "$dir/build-info.json" ]] ||
        die "refusing to replace an unrecognized output directory: $dir"
    build_info="$(<"$dir/build-info.json")"
    jq -e \
        --arg build_id "$build_id" \
        --argjson outputs "$expected_outputs_json" \
        --argjson provenance "$expected_provenance_json" '
        type == "object" and
        (keys | sort) == [
            "build_id", "built_at", "environment", "generated_audio",
            "outputs", "provenance", "schema"
        ] and
        .schema == 2 and .build_id == $build_id and
        .outputs == $outputs and .provenance == $provenance and
        (.built_at | type == "string" and length > 0) and
        (.environment | type == "object" and
            (keys | sort) == ["dotnet", "ffmpeg", "wine"] and
            all(.[]; type == "string" and length > 0)) and
        (.generated_audio | type == "object" and
            (keys | sort) == ["bytes", "sha256"] and
            (.bytes | type == "number" and . > 0 and floor == .) and
            (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
    ' <<<"$build_info" >/dev/null ||
        die "refusing to replace output with invalid build metadata: $dir"
    generated_audio_bytes="$(jq -er '.generated_audio.bytes' <<<"$build_info")" ||
        die "could not read existing generated audio size"
    generated_audio_sha="$(jq -er '.generated_audio.sha256' <<<"$build_info")" ||
        die "could not read existing generated audio hash"

    while IFS=$'\t' read -r rel expected_sha; do
        verify_file "$dir/$rel" "$expected_sha"
    done <<<"$output_records"
    while IFS=$'\t' read -r rel expected_bytes expected_sha; do
        verify_file "$dir/$rel" "$expected_sha" "$expected_bytes"
    done <<<"$extra_records"
    while IFS= read -r rel; do
        verify_file "$dir/$rel" "$generated_audio_sha" "$generated_audio_bytes"
        if [[ -z "$first_audio" ]]; then
            first_audio="$dir/$rel"
        else
            cmp -s -- "$first_audio" "$dir/$rel" ||
                die "existing generated audio copies differ: $dir"
        fi
    done <<<"$audio_outputs"
    validate_audio_file "$first_audio"

    verify_exact_output_tree "$dir" "refusing to replace output with an unexpected file tree"
}

verify_exact_output_tree() {
    local dir=$1 description=$2 expected_tree actual_tree
    expected_tree="$({
        printf '%s\n' "$expected_output_paths"
        printf '%s\n' build-info.json
    } | awk '
        NF {
            print "f " $0
            path = $0
            while (sub("/[^/]+$", "", path)) print "d " path
        }
    ' | LC_ALL=C sort -u)"
    actual_tree="$(find "$dir" -xdev -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort)"
    [[ "$actual_tree" == "$expected_tree" ]] || {
        diff -u <(printf '%s\n' "$expected_tree") <(printf '%s\n' "$actual_tree") >&2 || true
        die "$description: $dir"
    }
}

fetch_locked() {
    local url=$1 destination=$2 expected_sha=$3 expected_bytes=$4
    if [[ -f "$destination" && ! -L "$destination" ]]; then
        if [[ "$(stat -c %s "$destination")" == "$expected_bytes" && "$(sha "$destination")" == "$expected_sha" ]]; then
            echo "cache hit: $(basename "$destination")"
            return
        fi
        ((offline == 0)) || die "cached download is corrupt in offline mode: $destination"
        rm -f -- "$destination"
    elif [[ -e "$destination" || -L "$destination" ]]; then
        die "cached download is not a regular file: $destination"
    fi
    ((offline == 0)) || die "download is not cached for offline mode: $destination"

    download_lock="$destination.lock"
    mkdir -- "$download_lock" 2>/dev/null ||
        die "another build is downloading: $destination"
    download_lock_owned=1

    # A build may have completed while this process was acquiring the lock.
    if [[ -f "$destination" && ! -L "$destination" ]] &&
        [[ "$(stat -c %s "$destination")" == "$expected_bytes" ]] &&
        [[ "$(sha "$destination")" == "$expected_sha" ]]; then
        rmdir -- "$download_lock"
        download_lock=""
        download_lock_owned=0
        echo "cache hit: $(basename "$destination")"
        return
    fi

    local partial="$destination.part" partial_bytes
    if [[ -e "$partial" || -L "$partial" ]]; then
        [[ -f "$partial" && ! -L "$partial" ]] ||
            die "partial download is not a regular file: $partial"
        partial_bytes="$(stat -c %s "$partial")"
        if ((partial_bytes > expected_bytes)); then
            rm -f -- "$partial"
        elif ((partial_bytes == expected_bytes)); then
            if [[ "$(sha "$partial")" == "$expected_sha" ]]; then
                mv -f -- "$partial" "$destination"
                rmdir -- "$download_lock"
                download_lock=""
                download_lock_owned=0
                echo "cache completed: $(basename "$destination")"
                return
            fi
            rm -f -- "$partial"
        fi
    fi
    echo "downloading: $url"
    if ! curl --fail --location --retry 5 --retry-all-errors --continue-at - \
        --output "$partial" "$url"; then
        die "download failed; the partial file was kept for a later retry: $partial"
    fi
    if [[ "$(stat -c %s "$partial")" != "$expected_bytes" ]] ||
        [[ "$(sha "$partial")" != "$expected_sha" ]]; then
        rm -f -- "$partial"
        die "download verification failed: $url"
    fi
    mv -f -- "$partial" "$destination"
    rmdir -- "$download_lock"
    download_lock=""
    download_lock_owned=0
}

verify_manifest_members() {
    local base=$1 query=$2 records
    records="$(jq -er "$query[] | [.rel, (.bytes|tostring), .sha256] | @tsv" "$version_file")" ||
        die "could not read locked file members: $query"
    while IFS=$'\t' read -r rel expected_bytes expected_sha; do
        verify_file "$base/$rel" "$expected_sha" "$expected_bytes"
    done <<<"$records"
}

"$root/scripts/check_version_lock.sh" "$version_file"
version_lock_sha="$(sha "$version_file")"
build_id="$(jq -er '.id' "$version_file")" || die "could not read build id"
keucher_submodule="$(jq -er '.upstreams.keucher.path' "$version_file")" || die "could not read Keucher submodule path"
ump_submodule="$(jq -er '.upstreams.ump.path' "$version_file")" || die "could not read UMP submodule path"
drc_submodule="$(jq -er '.upstreams.deltarune_chinese.path' "$version_file")" || die "could not read DeltaruneChinese submodule path"
keucher_commit="$(jq -er '.upstreams.keucher.source_commit' "$version_file")" || die "could not read Keucher commit"
ump_commit="$(jq -er '.upstreams.ump.source_commit' "$version_file")" || die "could not read UMP commit"
drc_commit="$(jq -er '.upstreams.deltarune_chinese.commit' "$version_file")" || die "could not read DeltaruneChinese commit"
utmt_url="$(jq -er '.tools.undertale_mod_cli.url' "$version_file")" || die "could not read UTMT URL"
utmt_archive_name="$(jq -er '.tools.undertale_mod_cli.archive' "$version_file")" || die "could not read UTMT archive name"
utmt_sha="$(jq -er '.tools.undertale_mod_cli.sha256' "$version_file")" || die "could not read UTMT hash"
utmt_bytes="$(jq -er '.tools.undertale_mod_cli.bytes' "$version_file")" || die "could not read UTMT size"
flips_url="$(jq -er '.tools.flips.url' "$version_file")" || die "could not read Flips URL"
flips_archive_name="$(jq -er '.tools.flips.archive' "$version_file")" || die "could not read Flips archive name"
flips_sha="$(jq -er '.tools.flips.sha256' "$version_file")" || die "could not read Flips hash"
flips_bytes="$(jq -er '.tools.flips.bytes' "$version_file")" || die "could not read Flips size"
keucher_adapter_rel="$(jq -er '.adapters.keucher.rel' "$version_file")" || die "could not read Keucher adapter path"
drc_adapter_rel="$(jq -er '.adapters.deltarune_chinese.rel' "$version_file")" || die "could not read DeltaruneChinese adapter path"
packages_lock_rel="$(jq -er '.adapters.packages_lock.rel' "$version_file")" || die "could not read NuGet lock path"
audio_source_rel="$(jq -er '.audio.source' "$version_file")" || die "could not read audio source path"
audio_source_sha="$(jq -er '.audio.source_sha256' "$version_file")" || die "could not read audio source hash"
audio_source_bytes="$(jq -er '.audio.source_bytes' "$version_file")" || die "could not read audio source size"
audio_quality="$(jq -er '.audio.quality' "$version_file")" || die "could not read audio quality"
audio_codec="$(jq -er '.audio.codec' "$version_file")" || die "could not read audio codec"
audio_sample_rate="$(jq -er '.audio.sample_rate | tostring' "$version_file")" || die "could not read audio sample rate"
audio_channels="$(jq -er '.audio.channels' "$version_file")" || die "could not read audio channel count"
audio_duration="$(jq -er '.audio.duration' "$version_file")" || die "could not read audio duration"
audio_fingerprint_seconds="$(jq -er '.audio.fingerprint_seconds' "$version_file")" || die "could not read audio fingerprint length"
audio_fingerprint_min_similarity="$(jq -er '.audio.fingerprint_min_similarity' "$version_file")" || die "could not read audio fingerprint threshold"
audio_fingerprint_raw="$(jq -er '.audio.fingerprint_raw' "$version_file")" || die "could not read audio fingerprint"
expected_outputs_json="$(jq -ce '[.deltarune.files[] | {rel, sha256: .output_sha256}]' "$version_file")" ||
    die "could not read expected output records"
expected_provenance_json="$(jq -ce '{
    upstreams, adapters, undertale_mod_cli: .tools.undertale_mod_cli, audio
}' "$version_file")" || die "could not read expected build provenance"
output_records="$(jq -er '.deltarune.files[] | [.rel, .output_sha256] | @tsv' "$version_file")" ||
    die "could not read locked output hashes"
extra_records="$(jq -er '.output_extras[] | [.rel, (.bytes|tostring), .sha256] | @tsv' "$version_file")" ||
    die "could not read locked output extras"
audio_outputs="$(jq -er '.audio.outputs[]' "$version_file")" || die "could not read audio output paths"
expected_output_paths="$(jq -er '.deltarune.files[].rel, .output_extras[].rel, .audio.outputs[]' "$version_file")" ||
    die "could not read expected output paths"

note "Validating the clean game input"
game_records="$(jq -er '.deltarune.files[] | [.rel, (.bytes|tostring), .sha256] | @tsv' "$version_file")" ||
    die "could not read locked game files"
while IFS=$'\t' read -r rel expected_bytes expected_sha; do
    verify_file "$game_dir/$rel" "$expected_sha" "$expected_bytes"
done <<<"$game_records"
verify_manifest_members "$game_dir" '.deltarune.required_extras'

mkdir -p "$cache_dir/downloads" "$cache_dir/nuget" "$cache_dir/wine64" \
    "$work_base" "$output_parent"
[[ "$(readlink -f -- "$output_parent")" == "$output_parent" &&
    "$(readlink -m -- "$output_dir")" == "$output_dir" ]] ||
    die "the output path changed while preparing its parent"
paths_overlap "$output_dir" "$game_dir" && die "the output directory now overlaps the game directory"
require_safe_repo_write_path "$output_dir" "the output directory"
output_lock="$output_parent/.dr-tas-chs-$(basename -- "$output_dir").lock"
mkdir -- "$output_lock" 2>/dev/null ||
    die "another build is using the output directory: $output_dir"
output_lock_owned=1
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    validate_existing_output "$output_dir"
fi
if [[ -n "$patchset_dir" ]]; then
    patchset_parent="$(dirname -- "$patchset_dir")"
    mkdir -p -- "$patchset_parent"
    [[ "$(readlink -f -- "$patchset_parent")" == "$patchset_parent" &&
        "$(readlink -m -- "$patchset_dir")" == "$patchset_dir" ]] ||
        die "the patchset path changed while preparing its parent"
    paths_overlap "$patchset_dir" "$game_dir" && die "the patchset directory now overlaps the game directory"
    paths_overlap "$patchset_dir" "$output_dir" && die "the patchset directory now overlaps the output directory"
    require_safe_repo_write_path "$patchset_dir" "the patchset directory"
    acquire_patchset_lock "$patchset_parent" "$(basename -- "$patchset_dir")"
    if [[ -e "$patchset_dir" || -L "$patchset_dir" ]]; then
        "$root/scripts/create_patchset.sh" \
            --validate-only "$patchset_dir" \
            --version-file "$version_file"
    fi
fi

available_kib="$(df -Pk "$work_base" | awk 'NR==2 {print $4}')"
required_kib=$((4 * 1024 * 1024))
((available_kib >= required_kib)) ||
    die "at least 4 GiB free space is required in $work_base"

run_dir="$(mktemp -d "$work_base/dr-tas-chs-build-XXXXXX")"
chmod 700 -- "$run_dir"
staging_dir="$(mktemp -d "$output_parent/.dr-tas-chs-output.XXXXXX")"
chmod 700 -- "$staging_dir"
staging_identity="$(stat -c '%d:%i' -- "$staging_dir")"

ensure_submodule() {
    local rel=$1 expected_commit=$2
    local source="$root/$rel"
    if ! git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        ((offline == 0)) || die "submodule is not initialized in offline mode: $rel"
        git -C "$root" submodule update --init -- "$rel" ||
            die "could not initialize submodule: $rel"
    fi
    if ! git -C "$source" cat-file -e "$expected_commit^{commit}" 2>/dev/null; then
        ((offline == 0)) || die "submodule commit object is unavailable in offline mode: $rel"
        git -C "$root" submodule update --init -- "$rel" ||
            die "could not fetch locked submodule commit: $rel"
    fi
    git -C "$source" cat-file -e "$expected_commit^{commit}" 2>/dev/null ||
        die "locked submodule commit is unavailable: $rel ($expected_commit)"
}

note "Validating locked source submodules"
ensure_submodule "$keucher_submodule" "$keucher_commit"
ensure_submodule "$ump_submodule" "$ump_commit"
ensure_submodule "$drc_submodule" "$drc_commit"

utmt_archive="$cache_dir/downloads/$utmt_archive_name"
note "Fetching the locked UndertaleModTool CLI"
fetch_locked "$utmt_url" "$utmt_archive" "$utmt_sha" "$utmt_bytes"

utmt_dir="$run_dir/undertale-mod-tool-cli"
mkdir -- "$utmt_dir"
unzip -q "$utmt_archive" -d "$utmt_dir"
verify_manifest_members "$utmt_dir" '.tools.undertale_mod_cli.members'
chmod u+x "$utmt_dir/UndertaleModCli"

flips_binary=""
if [[ -n "$patchset_dir" ]]; then
    flips_archive="$cache_dir/downloads/$flips_archive_name"
    note "Fetching the locked Flips patch tool"
    fetch_locked "$flips_url" "$flips_archive" "$flips_sha" "$flips_bytes"
    flips_dir="$run_dir/flips"
    mkdir -- "$flips_dir"
    unzip -q "$flips_archive" -d "$flips_dir"
    verify_manifest_members "$flips_dir" '.tools.flips.members'
    flips_binary="$flips_dir/flips"
    chmod u+x "$flips_binary"
fi

keucher_adapter="$root/$keucher_adapter_rel"
drc_adapter="$root/$drc_adapter_rel"
adapter_packages_lock="$root/$packages_lock_rel"
adapter_records="$(jq -er '.adapters[] | [.rel, (.bytes|tostring), .sha256] | @tsv' "$version_file")" ||
    die "could not read locked adapter records"
while IFS=$'\t' read -r adapter_rel adapter_bytes adapter_sha; do
    verify_file "$root/$adapter_rel" "$adapter_sha" "$adapter_bytes"
done <<<"$adapter_records"

keucher_build="$run_dir/keucher-baseline"
note "Building all six Keucher baselines from source"
TMPDIR="$run_dir" "$root/scripts/build_keucher_from_source.sh" \
    --game-dir "$game_dir" \
    --output-dir "$keucher_build" \
    --utmt "$utmt_dir/UndertaleModCli" \
    --keucher-dir "$root/$keucher_submodule" \
    --ump-dir "$root/$ump_submodule" \
    --adapter "$keucher_adapter" \
    --version-file "$version_file"
keucher_records="$(jq -er '.deltarune.files[] | [.rel, .keucher_sha256] | @tsv' "$version_file")" ||
    die "could not read locked Keucher hashes"
while IFS=$'\t' read -r rel expected_sha; do
    verify_file "$keucher_build/$rel" "$expected_sha"
done <<<"$keucher_records"

drc_source="$run_dir/deltarune-chinese"
mkdir -- "$drc_source"
git -C "$root/$drc_submodule" archive \
    "$drc_commit" |
    tar -xf - -C "$drc_source"

note "Applying the audited DeltaruneChinese adapter"
patch --batch --fuzz=0 --directory="$drc_source" -p1 < "$drc_adapter"
cp "$adapter_packages_lock" "$drc_source/src/packages.lock.json"
remove_tree "$drc_source/workspace/result"

export WINEPREFIX="$cache_dir/wine64"
export WINEARCH=win64
export WINEDEBUG=-all
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export NUGET_PACKAGES="$cache_dir/nuget"
export DELTARUNE_CHINESE_DIR="$drc_source"

probe_restore_args=()
if ((offline)); then
    probe_nuget_config="$run_dir/NuGet.probe-offline.config"
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<configuration><packageSources><clear /></packageSources></configuration>' \
        > "$probe_nuget_config"
    probe_restore_args+=(--configfile "$probe_nuget_config")
fi
note "Preparing the DataWinProbe verifier"
dotnet restore "$root/tools/DataWinProbe/DataWinProbe.csproj" "${probe_restore_args[@]}"
export DATAWIN_PROBE_NO_RESTORE=1

cp "$keucher_build/data.win" "$drc_source/workspace/main/data.win"
for chapter in 1 2 3 4 5; do
    cp "$keucher_build/chapter${chapter}_windows/data.win" \
        "$drc_source/workspace/ch${chapter}/data.win"
done

note "Merging Keucher compatibility hooks into the CHS workspace"
"$root/scripts/apply_keucher_savestate_hotfix.sh" "$drc_source/workspace" "$keucher_build"
"$root/scripts/apply_ch5_v0247_compat.sh" "$drc_source/workspace"

note "Building the locked DeltaruneChinese packer"
restore_args=(--locked-mode)
if ((offline)); then
    offline_nuget_config="$run_dir/NuGet.offline.config"
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<configuration><packageSources><clear /></packageSources></configuration>' \
        > "$offline_nuget_config"
    restore_args+=(--configfile "$offline_nuget_config")
fi
dotnet restore "$drc_source/src/deltarunePacker.csproj" "${restore_args[@]}"
dotnet build -c Release --no-restore "$drc_source/src/deltarunePacker.csproj"
(
    cd "$drc_source"
    dotnet src/bin/Release/net10.0/deltarunePacker.dll workspace
)

note "Restoring Keucher savestate instrumentation"
"$root/scripts/reinstrument_keucher_savestate_v2.sh" \
    "$drc_source/workspace" "$drc_source/workspace/result"

cp "$drc_source/workspace/result/main/data.win" "$staging_dir/data.win"
for chapter in 1 2 3 4 5; do
    chapter_out="$staging_dir/chapter${chapter}_windows"
    mkdir -p "$chapter_out/lang"
    cp "$drc_source/workspace/result/ch${chapter}/data.win" "$chapter_out/data.win"
    cp "$drc_source/workspace/result/ch${chapter}"/lang_*.json "$chapter_out/lang/"
done

mkdir -p \
    "$staging_dir/chapter3_windows/vid" \
    "$staging_dir/chapter5_windows/vid" \
    "$staging_dir/chapter5_windows/mus" \
    "$staging_dir/vid" \
    "$staging_dir/mus"
cp "$drc_source/workspace/ch3/vid"/*.mp4 "$staging_dir/chapter3_windows/vid/"
cp "$drc_source/workspace/ch5/vid/ch5_intro_en.mp4" \
    "$staging_dir/chapter5_windows/vid/ch5_intro_en.mp4"
cp "$game_dir/chapter5_windows/vid/ch5_intro_jp.mp4" \
    "$staging_dir/chapter5_windows/vid/ch5_intro_jp.mp4"
cp "$staging_dir/chapter5_windows/vid/ch5_intro_en.mp4" "$staging_dir/vid/"
cp "$staging_dir/chapter5_windows/vid/ch5_intro_jp.mp4" "$staging_dir/vid/"

audio_source="$drc_source/$audio_source_rel"
verify_file "$audio_source" "$audio_source_sha" "$audio_source_bytes"
ffmpeg -nostdin -v error -y -i "$audio_source" -map_metadata -1 \
    -c:a libvorbis -q:a "$audio_quality" \
    -ar "$audio_sample_rate" \
    -ac "$audio_channels" \
    "$staging_dir/mus/ch5_intro_audio.ogg"
cp "$staging_dir/mus/ch5_intro_audio.ogg" \
    "$staging_dir/chapter5_windows/mus/ch5_intro_audio.ogg"

note "Applying final coexistence hotfixes"
"$root/scripts/apply_savestate_performance_hotfix.sh" "$staging_dir"
"$root/scripts/apply_ch5_pause_savestate_hotfix.sh" \
    "$staging_dir/chapter5_windows/data.win"
"$root/scripts/apply_ch5_rhythm_evaluation_font_hotfix.sh" \
    "$staging_dir/chapter5_windows/data.win"

note "Verifying the complete output"
while IFS=$'\t' read -r rel expected_sha; do
    verify_file "$staging_dir/$rel" "$expected_sha"
done <<<"$output_records"
while IFS=$'\t' read -r rel expected_bytes expected_sha; do
    verify_file "$staging_dir/$rel" "$expected_sha" "$expected_bytes"
done <<<"$extra_records"

validate_audio_file "$staging_dir/mus/ch5_intro_audio.ogg"
cmp -s "$staging_dir/mus/ch5_intro_audio.ogg" \
    "$staging_dir/chapter5_windows/mus/ch5_intro_audio.ogg" ||
    die "root and Chapter 5 audio copies differ"

"$root/scripts/verify_merged_output.sh" "$staging_dir"

build_info_tmp="$run_dir/build-info.json"
jq -n \
    --arg schema "2" \
    --arg build_id "$build_id" \
    --arg built_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg dotnet "$(dotnet --version)" \
    --arg wine "$(wine --version)" \
    --arg ffmpeg "$(ffmpeg -version | head -n1)" \
    --argjson provenance "$expected_provenance_json" \
    --arg audio_sha256 "$(sha "$staging_dir/mus/ch5_intro_audio.ogg")" \
    --argjson audio_bytes "$(stat -c %s "$staging_dir/mus/ch5_intro_audio.ogg")" \
    --argjson outputs "$expected_outputs_json" \
    '{schema: ($schema|tonumber), build_id: $build_id, built_at: $built_at,
      provenance: $provenance,
      environment: {dotnet: $dotnet, wine: $wine, ffmpeg: $ffmpeg},
      outputs: $outputs,
      generated_audio: {bytes: $audio_bytes, sha256: $audio_sha256}}' > "$build_info_tmp"
mv "$build_info_tmp" "$staging_dir/build-info.json"

verify_exact_output_tree "$staging_dir" "generated output contains a missing or unexpected tree entry"
[[ "$(sha "$version_file")" == "$version_lock_sha" ]] ||
    die "version lock changed during the build"
while IFS=$'\t' read -r rel expected_bytes expected_sha; do
    verify_file "$game_dir/$rel" "$expected_sha" "$expected_bytes"
done <<<"$game_records"
verify_manifest_members "$game_dir" '.deltarune.required_extras'

if [[ -n "$patchset_dir" ]]; then
    note "Generating the complete local BPS patchset"
    patchset_reservation="$(mktemp -d "$patchset_parent/.dr-tas-chs-patchset-build.XXXXXX")"
    chmod 700 -- "$patchset_reservation"
    patchset_staging="$patchset_reservation/patchset"
    "$root/scripts/create_patchset.sh" \
        --game-dir "$game_dir" \
        --output-dir "$staging_dir" \
        --destination "$patchset_staging" \
        --flips "$flips_binary" \
        --version-file "$version_file"
    [[ -d "$patchset_staging" && ! -L "$patchset_staging" ]] ||
        die "patchset generator did not publish a regular directory"
    patchset_staging_identity="$(stat -c '%d:%i' -- "$patchset_staging")"
fi

[[ "$(readlink -m -- "$output_dir")" == "$output_dir" ]] ||
    die "the output path changed before publication"
paths_overlap "$output_dir" "$game_dir" && die "the output path now overlaps the game directory"
require_safe_repo_write_path "$output_dir" "the output directory"
[[ -d "$staging_dir" && ! -L "$staging_dir" &&
    "$(stat -c '%d:%i' -- "$staging_dir")" == "$staging_identity" ]] ||
    die "the output staging directory changed before publication"
assert_no_mounts_below "$staging_dir"
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    validate_existing_output "$output_dir"
fi
if [[ -n "$patchset_dir" ]]; then
    [[ "$(readlink -m -- "$patchset_dir")" == "$patchset_dir" ]] ||
        die "the patchset path changed before publication"
    paths_overlap "$patchset_dir" "$game_dir" && die "the patchset path now overlaps the game directory"
    paths_overlap "$patchset_dir" "$output_dir" && die "the patchset path now overlaps the output directory"
    require_safe_repo_write_path "$patchset_dir" "the patchset directory"
    [[ -d "$patchset_staging" && ! -L "$patchset_staging" &&
        "$(stat -c '%d:%i' -- "$patchset_staging")" == "$patchset_staging_identity" ]] ||
        die "the patchset staging directory changed before publication"
    assert_no_mounts_below "$patchset_staging"
    if [[ -e "$patchset_dir" || -L "$patchset_dir" ]]; then
        "$root/scripts/create_patchset.sh" \
            --validate-only "$patchset_dir" \
            --version-file "$version_file"
    fi
fi

output_publish_reservation="$(mktemp -d "$output_parent/.dr-tas-chs-publish.XXXXXX")"
chmod 700 -- "$output_publish_reservation"
previous_output="$output_publish_reservation/previous-output"
if [[ -e "$output_dir" ]]; then
    mv -T -- "$output_dir" "$previous_output"
fi
if [[ -n "$patchset_dir" ]]; then
    previous_patchset="$patchset_reservation/previous-patchset"
    if [[ -e "$patchset_dir" || -L "$patchset_dir" ]]; then
        mv -T -- "$patchset_dir" "$previous_patchset"
    fi
fi
mv -T -- "$staging_dir" "$output_dir" || die "failed to publish the verified output"
new_output_published=1
staging_dir=""
if [[ -n "$patchset_dir" ]]; then
    mv -T -- "$patchset_staging" "$patchset_dir" || die "failed to publish the verified patchset"
    new_patchset_published=1
    patchset_staging=""
fi
publish_committed=1
new_output_published=0
new_patchset_published=0
if [[ -e "$previous_output" ]] && ! remove_tree "$previous_output"; then
    echo "warning: could not remove previous output: $previous_output" >&2
fi
previous_output=""
if [[ -n "$previous_patchset" && -e "$previous_patchset" ]]; then
    remove_tree "$previous_patchset" ||
        echo "warning: could not remove previous patchset: $previous_patchset" >&2
fi
previous_patchset=""
remove_tree "$output_publish_reservation"
output_publish_reservation=""
if [[ -n "$patchset_reservation" ]]; then
    remove_tree "$patchset_reservation"
    patchset_reservation=""
fi

echo
echo "Build completed and verified: $output_dir"
if [[ -n "$patchset_dir" ]]; then
    echo "BPS patchset completed and verified: $patchset_dir"
fi
echo "The game directory was not modified."
echo "Install explicitly with:"
echo "  ./install_output.sh apply --game-dir \"$game_dir\""
