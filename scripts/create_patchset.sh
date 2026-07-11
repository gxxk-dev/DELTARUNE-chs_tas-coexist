#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
game_dir=""
output_dir=""
destination=""
destination_argument=""
validate_only=""
version_file="$root/versions/pc-v0.0.247-f3437be-260710.json"
flips_argument=""
flips_path=""
staging=""
previous=""
publish_lock_fd=""
publish_lock_dir=""
validation_tmp=""
build_id=""
expected_provenance=""
expected_target_bindings=""
expected_locked_extra_bindings=""
audio_outputs_json=""
audio_codec=""
audio_sample_rate=""
audio_channels=""
audio_duration=""
audio_fingerprint_seconds=""
audio_fingerprint_min_similarity=""
audio_fingerprint_raw=""
declare -a files=()
declare -a output_extras=()
declare -a audio_outputs=()

patchset_readme='This local patchset was generated from a verified clean DELTARUNE installation
and the complete one-pass Keucher Mod + DeltaruneChinese coexist build.

Apply each targets[].patch to its targets[].rel vanilla file with Flips. Then
perform every derived_copies[] copy from source_rel to rel and copy each extras[]
path to its rel. Verify all byte counts and SHA-256 values in manifest.json.

Do not apply this patchset to a modified or different game version.'

usage() {
    cat <<'EOF'
Usage: scripts/create_patchset.sh --game-dir DIR --output-dir DIR --destination DIR [options]
       scripts/create_patchset.sh --validate-only DIR [--version-file FILE]

Create and verify a local vanilla-to-final BPS patchset plus all external files.
The input directories are read-only. The destination is replaced only after every
patch has been decoded and verified.

Options:
  --version-file FILE  Build version lock
  --flips FILE         Flips executable (default: resolve flips from PATH)
  --validate-only DIR  Maintenance interface: only validate an existing patchset
  -h, --help           Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

hash_file() {
    local digest
    digest="$(sha256sum -- "$1")"
    printf '%s\n' "${digest%% *}"
}

paths_overlap() {
    local first=$1 second=$2
    [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

is_safe_relative_path() {
    local path=$1 component
    local -a components=()

    [[ -n "$path" && "$path" != /* && "$path" != *\\* &&
        "$path" != *[[:cntrl:]]* &&
        "$path" != *//* && "$path" != */ ]] || return 1
    IFS='/' read -r -a components <<<"$path"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 1
    done
}

source_path_is_safe() {
    local source_root=$1 rel=$2 parent component accumulated=""
    local -a components=()

    is_safe_relative_path "$rel" || return 1
    [[ -d "$source_root" && ! -L "$source_root" ]] || return 1
    parent=${rel%/*}
    if [[ "$parent" != "$rel" ]]; then
        IFS='/' read -r -a components <<<"$parent"
        for component in "${components[@]}"; do
            if [[ -n "$accumulated" ]]; then
                accumulated+="/$component"
            else
                accumulated=$component
            fi
            [[ -d "$source_root/$accumulated" && ! -L "$source_root/$accumulated" ]] ||
                return 1
        done
    fi
    [[ -f "$source_root/$rel" && ! -L "$source_root/$rel" ]]
}

tree_has_mountpoint() {
    local tree=$1 mounts_json status

    mounts_json="$(findmnt -J -o TARGET 2>/dev/null)" || return 0
    if jq -e --arg tree "$tree" '
        [.. | objects | .target? // empty] |
        any(.[]; . == $tree or startswith($tree + "/"))
    ' <<<"$mounts_json" >/dev/null; then
        return 0
    else
        status=$?
        [[ "$status" -ne 1 ]]
    fi
}

safe_remove_tree() {
    local tree=$1 description=$2

    [[ -e "$tree" || -L "$tree" ]] || return 0
    if [[ ! -d "$tree" || -L "$tree" ]]; then
        echo "warning: refusing to remove unsafe $description; retained at: $tree" >&2
        return 1
    fi
    if tree_has_mountpoint "$tree"; then
        echo "warning: refusing to remove mounted $description; retained at: $tree" >&2
        return 1
    fi
    if ! rm -rf --one-file-system -- "$tree"; then
        echo "warning: could not remove $description; retained at: $tree" >&2
        return 1
    fi
}

open_regular_file() {
    local base=$1 rel=$2 result_var=$3 path opened_fd fd_path path_identity fd_identity

    source_path_is_safe "$base" "$rel" || return 1
    path="$base/$rel"
    exec {opened_fd}<"$path" || return 1
    fd_path="/proc/$$/fd/$opened_fd"
    if [[ ! -f "$path" || -L "$path" ]] ||
        [[ ! -f "$fd_path" ]] ||
        [[ "$(stat -Lc %h -- "$fd_path")" -ne 1 ]]; then
        exec {opened_fd}<&-
        return 1
    fi
    path_identity="$(stat -Lc '%d:%i' -- "$path")" || {
        exec {opened_fd}<&-
        return 1
    }
    fd_identity="$(stat -Lc '%d:%i' -- "$fd_path")" || {
        exec {opened_fd}<&-
        return 1
    }
    if [[ "$path_identity" != "$fd_identity" ]]; then
        exec {opened_fd}<&-
        return 1
    fi
    printf -v "$result_var" '%s' "$opened_fd"
}

file_descriptor_still_matches() {
    local base=$1 rel=$2 fd=$3 path="$base/$rel" fd_path="/proc/$$/fd/$fd"

    [[ -f "$path" && ! -L "$path" &&
        "$(stat -Lc %h -- "$fd_path")" -eq 1 &&
        "$(stat -Lc '%d:%i' -- "$path")" == "$(stat -Lc '%d:%i' -- "$fd_path")" ]]
}

read_regular_text_file() {
    local base=$1 rel=$2 result_var=$3 fd fd_path content

    open_regular_file "$base" "$rel" fd || return 1
    fd_path="/proc/$$/fd/$fd"
    content="$(<"$fd_path")" || {
        exec {fd}<&-
        return 1
    }
    if ! file_descriptor_still_matches "$base" "$rel" "$fd"; then
        exec {fd}<&-
        return 1
    fi
    exec {fd}<&-
    printf -v "$result_var" '%s' "$content"
}

verify_regular_file() {
    local base=$1 rel=$2 expected_bytes=${3:-} expected_sha=${4:-} expected_mode=${5:-}
    local fd fd_path actual_bytes actual_sha actual_mode

    open_regular_file "$base" "$rel" fd ||
        die "patchset member is not a regular single-linked file: $rel"
    fd_path="/proc/$$/fd/$fd"
    actual_bytes="$(stat -Lc %s -- "$fd_path")"
    actual_mode="$(stat -Lc %a -- "$fd_path")"
    actual_sha="$(hash_file "$fd_path")" || die "could not hash patchset member: $rel"
    if ! file_descriptor_still_matches "$base" "$rel" "$fd"; then
        exec {fd}<&-
        die "patchset member changed while it was verified: $rel"
    fi
    exec {fd}<&-

    [[ -z "$expected_bytes" || "$actual_bytes" == "$expected_bytes" ]] ||
        die "patchset member byte count mismatch: $rel"
    [[ -z "$expected_sha" || "$actual_sha" == "$expected_sha" ]] ||
        die "patchset member hash mismatch: $rel"
    [[ -z "$expected_mode" || "$actual_mode" == "$expected_mode" ]] ||
        die "patchset member mode mismatch: $rel"
}

validate_audio_file() {
    local base=$1 rel=$2 fd fd_path probe actual_duration
    local fingerprint_output actual_fingerprint similarity

    open_regular_file "$base" "$rel" fd ||
        die "generated audio is not a regular single-linked file: $rel"
    fd_path="/proc/$$/fd/$fd"
    probe="$(ffprobe -v error \
        -show_entries stream=codec_type,codec_name,sample_rate,channels \
        -show_entries format=duration -of json -- "$fd_path")" ||
        die "could not inspect generated audio: $rel"
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
    ' <<<"$probe" >/dev/null || die "generated audio properties are invalid: $rel"
    actual_duration="$(jq -er '.format.duration' <<<"$probe")" ||
        die "could not read generated audio duration: $rel"
    awk -v actual="$actual_duration" -v expected="$audio_duration" '
        BEGIN {
            delta = actual - expected
            if (delta < 0) delta = -delta
            exit(delta > 0.001)
        }
    ' || die "generated audio duration does not match the version lock: $rel"

    fingerprint_output="$(fpcalc -raw -length "$audio_fingerprint_seconds" "$fd_path")" ||
        die "could not calculate the audio fingerprint: $rel"
    actual_fingerprint="$(awk -F= '
        $1 == "FINGERPRINT" {print substr($0, index($0, "=") + 1)}
    ' <<<"$fingerprint_output")"
    [[ "$actual_fingerprint" =~ ^[0-9]+(,[0-9]+)+$ ]] ||
        die "fpcalc returned an invalid fingerprint: $rel"
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
    ')" || die "audio fingerprint length does not match the version lock: $rel"
    awk -v actual="$similarity" -v minimum="$audio_fingerprint_min_similarity" \
        'BEGIN { exit(actual + 0 < minimum + 0) }' ||
        die "audio fingerprint does not match the locked source: $rel (similarity $similarity)"
    if ! file_descriptor_still_matches "$base" "$rel" "$fd"; then
        exec {fd}<&-
        die "generated audio changed while it was verified: $rel"
    fi
    exec {fd}<&-
}

load_version_metadata() {
    local file_records extra_records audio_records

    build_id="$(jq -er '.id' "$version_file")" || die "could not read build id"
    expected_provenance="$(jq -ce '{
        upstreams: .upstreams,
        adapters: .adapters,
        undertale_mod_cli: .tools.undertale_mod_cli,
        audio: .audio
    }' "$version_file")" || die "could not read expected provenance"
    expected_target_bindings="$(jq -ce '[.deltarune.files[] | {
        id, rel, source_bytes: .bytes, source_sha256: .sha256,
        output_sha256: .output_sha256
    }]' "$version_file")" || die "could not read target bindings"
    expected_locked_extra_bindings="$(jq -ce '[.output_extras[] | {
        rel, path: ("extras/" + .rel), bytes, sha256,
        origin: "locked_output_extra"
    }]' "$version_file")" || die "could not read external output bindings"
    audio_outputs_json="$(jq -ce '.audio.outputs' "$version_file")" ||
        die "could not read generated audio output paths"
    audio_codec="$(jq -er '.audio.codec' "$version_file")" ||
        die "could not read audio codec"
    audio_sample_rate="$(jq -er '.audio.sample_rate | tostring' "$version_file")" ||
        die "could not read audio sample rate"
    audio_channels="$(jq -er '.audio.channels' "$version_file")" ||
        die "could not read audio channel count"
    audio_duration="$(jq -er '.audio.duration' "$version_file")" ||
        die "could not read audio duration"
    audio_fingerprint_seconds="$(jq -er '.audio.fingerprint_seconds' "$version_file")" ||
        die "could not read audio fingerprint length"
    audio_fingerprint_min_similarity="$(jq -er '.audio.fingerprint_min_similarity' "$version_file")" ||
        die "could not read audio fingerprint threshold"
    audio_fingerprint_raw="$(jq -er '.audio.fingerprint_raw' "$version_file")" ||
        die "could not read locked audio fingerprint"

    file_records="$(jq -er '
        .deltarune.files[] |
        [.id, .rel, (.bytes | tostring), .sha256, .output_sha256] | @tsv
    ' "$version_file")" || die "could not read game file records"
    mapfile -t files <<<"$file_records"
    [[ "${#files[@]}" -eq 6 ]] || die "version lock must define six game files"

    extra_records="$(jq -er '
        .output_extras[] | [.rel, (.bytes | tostring), .sha256] | @tsv
    ' "$version_file")" || die "could not read external output records"
    mapfile -t output_extras <<<"$extra_records"
    [[ "${#output_extras[@]}" -eq 21 ]] ||
        die "version lock must define exactly 21 locked external outputs"

    audio_records="$(jq -er '.audio.outputs[]' "$version_file")" ||
        die "could not read generated audio output paths"
    mapfile -t audio_outputs <<<"$audio_records"
    [[ "${#audio_outputs[@]}" -eq 2 ]] ||
        die "version lock must define two audio outputs"
}

verify_patchset_tree() {
    local base=$1 description=${2:-patchset} manifest_json target_records derived_records extra_records
    local id rel patch source_bytes source_sha output_bytes output_sha patch_bytes patch_sha extra
    local operation source_target_id source_rel bytes sha path mode origin expected_rel
    local readme_sha_line readme_sha readme_bytes kind entry parent entry_count=0
    local -a expected_files=(manifest.json README.txt)
    local -A expected_entries=() seen_entries=()
    local -A target_rels=() target_bytes=() target_hashes=()

    [[ -d "$base" && ! -L "$base" && "$(readlink -f -- "$base")" == "$base" ]] ||
        die "$description is not a physical regular directory: $base"
    tree_has_mountpoint "$base" && die "$description contains a mountpoint: $base"
    read_regular_text_file "$base" manifest.json manifest_json ||
        die "$description has an unsafe or unreadable manifest.json"

    jq -e --arg build_id "$build_id" --argjson provenance "$expected_provenance" '
        def exact_keys($wanted):
            type == "object" and ((keys | sort) == ($wanted | sort));
        def positive_integer: type == "number" and . > 0 and floor == .;
        def digest: type == "string" and test("^[0-9a-f]{64}$");
        def safe_path:
            type == "string" and length > 0 and
            (startswith("/") | not) and (endswith("/") | not) and
            (contains("\\") | not) and (contains("//") | not) and
            (test("[\\x00-\\x1f]") | not) and
            (split("/") | all(.[]; length > 0 and . != "." and . != ".."));

        exact_keys([
            "schema", "build_id", "created_at", "provenance",
            "targets", "derived_copies", "extras"
        ]) and
        .schema == 2 and .build_id == $build_id and .provenance == $provenance and
        (.created_at | type == "string" and
            test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
        (.targets | type == "array" and length == 6) and
        all(.targets[];
            exact_keys([
                "id", "rel", "patch", "source_bytes", "source_sha256",
                "output_bytes", "output_sha256", "patch_bytes", "patch_sha256"
            ]) and
            (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
            (.rel | safe_path) and (.patch | safe_path) and
            (.source_bytes | positive_integer) and (.source_sha256 | digest) and
            (.output_bytes | positive_integer) and (.output_sha256 | digest) and
            (.patch_bytes | positive_integer) and (.patch_sha256 | digest)
        ) and
        (.derived_copies | type == "array" and length == 5) and
        all(.derived_copies[];
            exact_keys([
                "operation", "source_target_id", "source_rel", "rel", "bytes", "sha256"
            ]) and .operation == "copy" and
            (.source_target_id | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")) and
            (.source_rel | safe_path) and (.rel | safe_path) and
            (.bytes | positive_integer) and (.sha256 | digest)
        ) and
        (.extras | type == "array" and length == 23) and
        all(.extras[];
            exact_keys(["rel", "path", "bytes", "sha256", "mode", "origin"]) and
            (.rel | safe_path) and (.path | safe_path) and
            (.bytes | positive_integer) and (.sha256 | digest) and
            (.mode | type == "string" and test("^[0-7]{3}$")) and
            (.origin == "locked_output_extra" or .origin == "generated_audio")
        ) and
        ([.targets[].id] | length == (unique | length)) and
        (([.targets[].rel] + [.derived_copies[].rel] + [.extras[].rel]) |
            length == (unique | length)) and
        (([.targets[].patch] + [.extras[].path]) | length == (unique | length))
    ' <<<"$manifest_json" >/dev/null ||
        die "$description manifest schema, build id, or provenance is invalid"

    jq -e --argjson expected "$expected_target_bindings" '
        [.targets[] | {
            id, rel, source_bytes, source_sha256, output_sha256
        }] == $expected
    ' <<<"$manifest_json" >/dev/null ||
        die "$description targets do not match the version lock"
    jq -e --argjson expected "$expected_locked_extra_bindings" '
        [.extras[0:21][] | {rel, path, bytes, sha256, origin}] == $expected
    ' <<<"$manifest_json" >/dev/null ||
        die "$description locked extras do not match the version lock"
    jq -e --argjson audio_outputs "$audio_outputs_json" '
        (.extras[21:] | map(.rel)) == $audio_outputs and
        all(.extras[21:][];
            .path == ("extras/" + .rel) and .origin == "generated_audio") and
        .extras[21].bytes == .extras[22].bytes and
        .extras[21].sha256 == .extras[22].sha256
    ' <<<"$manifest_json" >/dev/null ||
        die "$description generated audio records are invalid"

    target_records="$(jq -er '
        .targets[] | [
            .id, .rel, .patch, (.source_bytes | tostring), .source_sha256,
            (.output_bytes | tostring), .output_sha256,
            (.patch_bytes | tostring), .patch_sha256
        ] | @tsv
    ' <<<"$manifest_json")" || die "could not read $description target records"
    while IFS=$'\t' read -r id rel patch source_bytes source_sha output_bytes output_sha \
        patch_bytes patch_sha extra; do
        [[ -z "${extra:-}" ]] || die "$description contains an invalid target record"
        is_safe_relative_path "$rel" || die "$description contains an unsafe target path: $rel"
        is_safe_relative_path "$patch" || die "$description contains an unsafe patch path: $patch"
        [[ "$patch" == "patches/$id.bps" ]] ||
            die "$description contains a noncanonical patch path: $patch"
        target_rels["$id"]=$rel
        target_bytes["$id"]=$output_bytes
        target_hashes["$id"]=$output_sha
        expected_files+=("$patch")
        verify_regular_file "$base" "$patch" "$patch_bytes" "$patch_sha"
    done <<<"$target_records"

    derived_records="$(jq -er '
        .derived_copies[] |
        [.operation, .source_target_id, .source_rel, .rel, (.bytes | tostring), .sha256] | @tsv
    ' <<<"$manifest_json")" || die "could not read $description derived copy records"
    while IFS=$'\t' read -r operation source_target_id source_rel rel bytes sha extra; do
        [[ -z "${extra:-}" ]] || die "$description contains an invalid derived copy record"
        is_safe_relative_path "$source_rel" && is_safe_relative_path "$rel" ||
            die "$description contains an unsafe derived copy path"
        [[ -n "${target_rels[$source_target_id]+x}" && "$source_target_id" != main ]] ||
            die "$description derived copy has an unknown source target"
        expected_rel="${target_rels[$source_target_id]%/*}/data_keucher.win"
        [[ "$operation" == copy && "$source_rel" == "${target_rels[$source_target_id]}" &&
            "$rel" == "$expected_rel" && "$bytes" == "${target_bytes[$source_target_id]}" &&
            "$sha" == "${target_hashes[$source_target_id]}" ]] ||
            die "$description contains an invalid derived copy for $source_target_id"
    done <<<"$derived_records"

    extra_records="$(jq -er '
        .extras[] | [.rel, .path, (.bytes | tostring), .sha256, .mode, .origin] | @tsv
    ' <<<"$manifest_json")" || die "could not read $description external file records"
    while IFS=$'\t' read -r rel path bytes sha mode origin extra; do
        [[ -z "${extra:-}" ]] || die "$description contains an invalid external file record"
        is_safe_relative_path "$rel" && is_safe_relative_path "$path" ||
            die "$description contains an unsafe external file path"
        [[ "$path" == "extras/$rel" ]] ||
            die "$description contains a noncanonical external file path: $path"
        expected_files+=("$path")
        verify_regular_file "$base" "$path" "$bytes" "$sha" "$mode"
    done <<<"$extra_records"

    for rel in "${audio_outputs[@]}"; do
        validate_audio_file "$base" "extras/$rel"
    done

    readme_sha_line="$(printf '%s\n' "$patchset_readme" | sha256sum)"
    readme_sha=${readme_sha_line%% *}
    readme_bytes=$((${#patchset_readme} + 1))
    verify_regular_file "$base" README.txt "$readme_bytes" "$readme_sha"

    for entry in "${expected_files[@]}"; do
        is_safe_relative_path "$entry" || die "internal error: unsafe expected patchset path: $entry"
        [[ -z "${expected_entries[$entry]+x}" ]] ||
            die "$description manifest references a path more than once: $entry"
        expected_entries["$entry"]=f
        parent=${entry%/*}
        while [[ "$parent" != "$entry" ]]; do
            if [[ -n "${expected_entries[$parent]+x}" && "${expected_entries[$parent]}" != d ]]; then
                die "$description has a file/directory path conflict: $parent"
            fi
            expected_entries["$parent"]=d
            entry=$parent
            parent=${entry%/*}
        done
    done

    validation_tmp="$(mktemp "${TMPDIR:-/tmp}/dr-tas-chs-patchset-tree.XXXXXX")"
    chmod 600 -- "$validation_tmp"
    find "$base" -mindepth 1 -printf '%y\0%P\0' >"$validation_tmp" ||
        die "could not enumerate $description"
    while IFS= read -r -d '' kind; do
        IFS= read -r -d '' entry || die "could not parse $description tree"
        [[ -n "${expected_entries[$entry]+x}" ]] ||
            die "$description contains an unexpected tree entry: $entry"
        [[ "$kind" == "${expected_entries[$entry]}" ]] ||
            die "$description contains an unsafe tree entry type: $entry"
        [[ -z "${seen_entries[$entry]+x}" ]] ||
            die "$description tree contains a duplicate entry: $entry"
        seen_entries["$entry"]=1
        ((entry_count += 1))
    done <"$validation_tmp"
    rm -f -- "$validation_tmp"
    validation_tmp=""
    [[ "$entry_count" -eq "${#expected_entries[@]}" ]] ||
        die "$description tree is missing expected entries"
    for entry in "${!expected_entries[@]}"; do
        [[ -n "${seen_entries[$entry]+x}" ]] ||
            die "$description tree is missing an expected entry: $entry"
    done
}

validate_lock_state() {
    local lock_path=$1 expected_uid=$2 expected_dir_identity=$3 fd=${4:-}
    local current_dir_identity path_identity fd_identity fd_path

    [[ -d "$publish_lock_dir" && ! -L "$publish_lock_dir" &&
        "$(readlink -f -- "$publish_lock_dir")" == "$publish_lock_dir" &&
        "$(stat -Lc %u -- "$publish_lock_dir")" == "$expected_uid" &&
        "$(stat -Lc %a -- "$publish_lock_dir")" == 700 ]] || return 1
    current_dir_identity="$(stat -Lc '%d:%i' -- "$publish_lock_dir")" || return 1
    [[ "$current_dir_identity" == "$expected_dir_identity" ]] || return 1
    [[ -f "$lock_path" && ! -L "$lock_path" &&
        "$(stat -Lc %u -- "$lock_path")" == "$expected_uid" &&
        "$(stat -Lc %a -- "$lock_path")" == 600 &&
        "$(stat -Lc %h -- "$lock_path")" -eq 1 &&
        "$(stat -Lc %s -- "$lock_path")" -eq 0 ]] || return 1
    if [[ -n "$fd" ]]; then
        fd_path="/proc/$$/fd/$fd"
        [[ -f "$fd_path" &&
            "$(stat -Lc %u -- "$fd_path")" == "$expected_uid" &&
            "$(stat -Lc %a -- "$fd_path")" == 600 &&
            "$(stat -Lc %h -- "$fd_path")" -eq 1 &&
            "$(stat -Lc %s -- "$fd_path")" -eq 0 ]] || return 1
        path_identity="$(stat -Lc '%d:%i' -- "$lock_path")" || return 1
        fd_identity="$(stat -Lc '%d:%i' -- "$fd_path")" || return 1
        [[ "$path_identity" == "$fd_identity" ]] || return 1
    fi
}

acquire_publish_lock() {
    local lock_path expected_uid dir_identity unexpected

    publish_lock_dir="${destination_parent%/}/.dr-tas-chs-$destination_name.lock"
    expected_uid="$(id -u)"
    if ! mkdir -m 700 -- "$publish_lock_dir" 2>/dev/null; then
        [[ -d "$publish_lock_dir" && ! -L "$publish_lock_dir" ]] ||
            die "publish lock path is not a private directory: $publish_lock_dir"
    fi
    [[ "$(readlink -f -- "$publish_lock_dir")" == "$publish_lock_dir" &&
        "$(stat -Lc %u -- "$publish_lock_dir")" == "$expected_uid" &&
        "$(stat -Lc %a -- "$publish_lock_dir")" == 700 ]] ||
        die "publish lock directory has unsafe ownership or mode: $publish_lock_dir"
    dir_identity="$(stat -Lc '%d:%i' -- "$publish_lock_dir")"
    unexpected="$(find "$publish_lock_dir" -mindepth 1 -maxdepth 1 \
        ! -name publish.lock -print -quit)" || die "could not inspect publish lock directory"
    [[ -z "$unexpected" ]] || die "publish lock directory contains an unexpected entry: $unexpected"

    lock_path="$publish_lock_dir/publish.lock"
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
        validate_lock_state "$lock_path" "$expected_uid" "$dir_identity" ||
            die "publish lock file has unsafe ownership, mode, type, or link count: $lock_path"
    else
        (umask 077; set -o noclobber; : >"$lock_path") 2>/dev/null || true
    fi
    exec {publish_lock_fd}<>"$lock_path"
    validate_lock_state "$lock_path" "$expected_uid" "$dir_identity" "$publish_lock_fd" ||
        die "publish lock file identity changed while it was opened: $lock_path"
    flock -n "$publish_lock_fd" || die "another patchset publication is active: $destination"
    validate_lock_state "$lock_path" "$expected_uid" "$dir_identity" "$publish_lock_fd" ||
        die "publish lock state changed after acquisition: $lock_path"
}

reject_destination_overlap() {
    local protected=$1 description=$2
    if paths_overlap "$destination" "$protected"; then
        die "destination may not overlap $description: $protected"
    fi
}

check_repository_destination() {
    local rel

    if [[ "$destination" == "$root" || "$root" == "$destination/"* ]]; then
        die "destination may not equal or contain the source repository: $root"
    fi
    if [[ "$destination" == "$root/"* ]]; then
        rel=${destination#"$root/"}
        git -C "$root" check-ignore -q --no-index -- "$rel/.probe" ||
            die "destination inside the repository must be gitignored: $destination"
    fi
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
        --destination)
            (($# >= 2)) || die "--destination requires a path"
            destination=$2
            shift 2
            ;;
        --version-file)
            (($# >= 2)) || die "--version-file requires a path"
            version_file=$2
            shift 2
            ;;
        --flips)
            (($# >= 2)) || die "--flips requires a path"
            flips_argument=$2
            shift 2
            ;;
        --validate-only)
            (($# >= 2)) || die "--validate-only requires a path"
            validate_only=$2
            shift 2
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

for command in awk bash basename chmod dirname ffprobe find findmnt fpcalc gawk git jq mktemp readlink rm sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done
[[ -d "/proc/$$/fd" ]] || die "/proc file descriptors are required"
LC_ALL=C
export LC_ALL
umask 077

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$validation_tmp" && -e "$validation_tmp" ]]; then
        rm -f -- "$validation_tmp" ||
            echo "warning: could not remove validation scratch file: $validation_tmp" >&2
        validation_tmp=""
    fi
    if [[ -n "$previous" && -e "$previous" ]]; then
        if [[ ! -e "$destination" && ! -L "$destination" ]]; then
            if mv -T -- "$previous" "$destination"; then
                echo "restored the previous patchset after an interrupted publish" >&2
                previous=""
            else
                echo "error: could not restore the previous patchset; it was retained at: $previous" >&2
            fi
        else
            echo "error: previous patchset could not be restored because the destination is occupied; retained at: $previous" >&2
        fi
    fi
    if [[ -n "$staging" && ( -e "$staging" || -L "$staging" ) ]]; then
        safe_remove_tree "$staging" "unpublished patchset staging tree" || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -f "$version_file" && ! -L "$version_file" ]] ||
    die "version lock is not a regular file: $version_file"
version_file="$(readlink -f -- "$version_file")"
bash "$root/scripts/check_version_lock.sh" "$version_file" >/dev/null ||
    die "version lock validation failed: $version_file"
load_version_metadata

if [[ -n "$validate_only" ]]; then
    [[ -z "$game_dir" && -z "$output_dir" && -z "$destination" && -z "$flips_argument" ]] ||
        die "--validate-only may only be combined with --version-file"
    [[ ! -L "$validate_only" ]] || die "patchset may not be a symbolic link: $validate_only"
    validate_name="$(basename -- "$(readlink -m -- "$validate_only")")"
    [[ -n "$validate_name" && "$validate_name" != . && "$validate_name" != .. &&
        "$validate_name" != *$'\n'* && "$validate_name" != *$'\r'* &&
        "$validate_name" != *$'\t'* ]] || die "patchset has an unsafe final component"
    validate_parent="$(dirname -- "$(readlink -m -- "$validate_only")")"
    [[ -d "$validate_parent" ]] || die "patchset parent directory does not exist: $validate_parent"
    validate_parent="$(readlink -f -- "$validate_parent")"
    validate_only="${validate_parent%/}/$validate_name"
    [[ -d "$validate_only" && ! -L "$validate_only" ]] ||
        die "patchset is not a regular directory: $validate_only"
    verify_patchset_tree "$validate_only" "patchset"
    echo "Patchset validation completed: $validate_only"
    exit 0
fi

[[ -n "$game_dir" && -n "$output_dir" && -n "$destination" ]] || {
    usage >&2
    exit 2
}
for command in cmp cp date ffprobe flock id mkdir mv; do
    command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done

[[ -d "$game_dir" ]] || die "game directory does not exist: $game_dir"
[[ -d "$output_dir" ]] || die "output directory does not exist: $output_dir"
game_dir="$(readlink -f -- "$game_dir")"
output_dir="$(readlink -f -- "$output_dir")"

if [[ -n "$flips_argument" ]]; then
    flips_candidate=$flips_argument
else
    flips_candidate="$(command -v flips || true)"
    [[ -n "$flips_candidate" ]] ||
        die "Flips was not found; pass the verified executable with --flips FILE"
fi
[[ -f "$flips_candidate" && ! -L "$flips_candidate" && -x "$flips_candidate" ]] ||
    die "Flips is not a regular executable file: $flips_candidate"
flips_path="$(readlink -f -- "$flips_candidate")"
[[ -f "$flips_path" && ! -L "$flips_path" && -x "$flips_path" ]] ||
    die "Flips is not a regular executable file: $flips_path"

destination_argument=$destination
[[ ! -L "$destination_argument" ]] || die "destination may not be a symbolic link"
destination="$(readlink -m -- "$destination_argument")"
[[ "$destination" != / ]] || die "destination may not be /"
destination_name="$(basename -- "$destination")"
[[ -n "$destination_name" && "$destination_name" != . && "$destination_name" != .. &&
    "$destination_name" != *$'\n'* && "$destination_name" != *$'\r'* &&
    "$destination_name" != *$'\t'* ]] || die "destination has an unsafe final component"
destination_parent="$(dirname -- "$destination")"

check_repository_destination
reject_destination_overlap "$game_dir" "the game input"
reject_destination_overlap "$output_dir" "the build output input"
reject_destination_overlap "$version_file" "the version lock"
reject_destination_overlap "$flips_path" "the Flips executable"

mkdir -p -- "$destination_parent"
destination_parent="$(readlink -f -- "$destination_parent")"
destination="${destination_parent%/}/$destination_name"
check_repository_destination
reject_destination_overlap "$game_dir" "the game input"
reject_destination_overlap "$output_dir" "the build output input"
if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] ||
        die "destination exists and is not a regular directory: $destination"
fi

acquire_publish_lock
if [[ -e "$destination" || -L "$destination" ]]; then
    verify_patchset_tree "$destination" "existing destination patchset"
fi

read_regular_text_file "$output_dir" build-info.json build_info_json ||
    die "missing or unsafe build metadata: $output_dir/build-info.json"
expected_outputs="$(jq -ce '[.deltarune.files[] | {rel, sha256: .output_sha256}]' \
    "$version_file")" || die "could not read expected outputs"
jq -e \
    --arg build_id "$build_id" \
    --argjson expected_outputs "$expected_outputs" \
    --argjson expected_provenance "$expected_provenance" '
    type == "object" and
    (keys | sort) == [
        "build_id", "built_at", "environment", "generated_audio",
        "outputs", "provenance", "schema"
    ] and
    .schema == 2 and .build_id == $build_id and
    .outputs == $expected_outputs and .provenance == $expected_provenance and
    (.environment | type == "object" and
        (keys | sort) == ["dotnet", "ffmpeg", "wine"] and
        all(.[]; type == "string" and length > 0)) and
    (.built_at | type == "string" and length > 0) and
    (.generated_audio |
        type == "object" and (keys | sort) == ["bytes", "sha256"] and
        (.bytes | type == "number" and . > 0 and floor == .) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
' <<<"$build_info_json" >/dev/null ||
    die "output build metadata does not match the version lock"
generated_audio_bytes="$(jq -er '.generated_audio.bytes' <<<"$build_info_json")" ||
    die "could not read generated audio byte count"
generated_audio_sha="$(jq -er '.generated_audio.sha256' <<<"$build_info_json")" ||
    die "could not read generated audio hash"

audio_codec="$(jq -er '.audio.codec' "$version_file")" || die "could not read audio codec"
audio_sample_rate="$(jq -er '.audio.sample_rate' "$version_file")" ||
    die "could not read audio sample rate"
audio_channels="$(jq -er '.audio.channels' "$version_file")" ||
    die "could not read audio channel count"
audio_duration="$(jq -er '.audio.duration' "$version_file")" ||
    die "could not read audio duration"

staging="$(mktemp -d "${destination_parent%/}/.dr-tas-chs-patchset.XXXXXX")"
previous="$staging.previous"
mkdir -p -- "$staging/patches" "$staging/extras"
targets_jsonl="$staging/.targets.jsonl"
extras_jsonl="$staging/.extras.jsonl"
derived_jsonl="$staging/.derived-copies.jsonl"
: >"$targets_jsonl"
: >"$extras_jsonl"
: >"$derived_jsonl"

copy_external_output() {
    local rel=$1 expected_bytes=$2 expected_sha=$3 origin=$4
    local source source_mode copied

    is_safe_relative_path "$rel" || die "unsafe external output path: $rel"
    source_path_is_safe "$output_dir" "$rel" || die "missing or unsafe external output: $rel"
    source="$output_dir/$rel"
    source_mode="$(stat -c %a -- "$source")"
    [[ "$(stat -c %s -- "$source")" == "$expected_bytes" &&
        "$(hash_file "$source")" == "$expected_sha" ]] ||
        die "external output does not match its expected content: $rel"

    copied="$staging/extras/$rel"
    mkdir -p -- "$(dirname -- "$copied")"
    cp --preserve=mode,timestamps -- "$source" "$copied"
    [[ -f "$copied" && ! -L "$copied" && "$(stat -c %h -- "$copied")" -eq 1 &&
        "$(stat -c %s -- "$copied")" == "$expected_bytes" &&
        "$(stat -c %a -- "$copied")" == "$source_mode" &&
        "$(hash_file "$copied")" == "$expected_sha" &&
        "$(stat -c %s -- "$source")" == "$expected_bytes" &&
        "$(hash_file "$source")" == "$expected_sha" ]] ||
        die "external output copy verification failed: $rel"

    jq -nc \
        --arg rel "$rel" --arg path "extras/$rel" --arg sha256 "$expected_sha" \
        --arg mode "$source_mode" --arg origin "$origin" --argjson bytes "$expected_bytes" '
        {
            rel: $rel, path: $path, bytes: $bytes, sha256: $sha256,
            mode: $mode, origin: $origin
        }
    ' >>"$extras_jsonl"
}

for record in "${files[@]}"; do
    IFS=$'\t' read -r id rel vanilla_bytes vanilla_sha output_sha extra <<<"$record"
    [[ -z "${extra:-}" ]] || die "invalid game file record"
    is_safe_relative_path "$rel" || die "unsafe game file path: $rel"
    [[ "$id" =~ ^[a-z0-9][a-z0-9._-]*$ && "$id" != . && "$id" != .. ]] ||
        die "unsafe game file id: $id"
    source_path_is_safe "$game_dir" "$rel" || die "missing or unsafe vanilla input: $rel"
    source_path_is_safe "$output_dir" "$rel" || die "missing or unsafe built output: $rel"

    source="$game_dir/$rel"
    result="$output_dir/$rel"
    [[ "$(stat -c %s -- "$source")" == "$vanilla_bytes" &&
        "$(hash_file "$source")" == "$vanilla_sha" ]] || die "vanilla input mismatch: $rel"
    [[ "$(hash_file "$result")" == "$output_sha" ]] || die "built output mismatch: $rel"
    result_bytes="$(stat -c %s -- "$result")"

    patch_rel="patches/$id.bps"
    patch="$staging/$patch_rel"
    verify="$staging/.verify-$id.win"
    "$flips_path" --create --exact --bps "$source" "$result" "$patch"
    [[ -f "$patch" && ! -L "$patch" ]] || die "Flips did not create a regular patch: $patch_rel"
    "$flips_path" --apply --exact "$patch" "$source" "$verify"
    [[ -f "$verify" && ! -L "$verify" && "$(stat -c %s -- "$verify")" == "$result_bytes" &&
        "$(hash_file "$verify")" == "$output_sha" ]] || die "BPS verification failed: $rel"
    [[ "$(stat -c %s -- "$source")" == "$vanilla_bytes" &&
        "$(hash_file "$source")" == "$vanilla_sha" &&
        "$(stat -c %s -- "$result")" == "$result_bytes" &&
        "$(hash_file "$result")" == "$output_sha" ]] ||
        die "an input changed while creating its patch: $rel"
    rm -- "$verify"

    patch_bytes="$(stat -c %s -- "$patch")"
    patch_sha="$(hash_file "$patch")"
    jq -nc \
        --arg id "$id" --arg rel "$rel" --arg patch "$patch_rel" \
        --arg source_sha256 "$vanilla_sha" --arg output_sha256 "$output_sha" \
        --arg patch_sha256 "$patch_sha" \
        --argjson source_bytes "$vanilla_bytes" --argjson output_bytes "$result_bytes" \
        --argjson patch_bytes "$patch_bytes" '
        {
            id: $id, rel: $rel, patch: $patch,
            source_bytes: $source_bytes, source_sha256: $source_sha256,
            output_bytes: $output_bytes, output_sha256: $output_sha256,
            patch_bytes: $patch_bytes, patch_sha256: $patch_sha256
        }
    ' >>"$targets_jsonl"

    if [[ "$id" != main ]]; then
        derived_rel="${rel%/*}/data_keucher.win"
        is_safe_relative_path "$derived_rel" || die "unsafe derived output path: $derived_rel"
        jq -nc \
            --arg source_target_id "$id" --arg source_rel "$rel" --arg rel "$derived_rel" \
            --arg sha256 "$output_sha" --argjson bytes "$result_bytes" '
            {
                operation: "copy", source_target_id: $source_target_id,
                source_rel: $source_rel, rel: $rel, bytes: $bytes, sha256: $sha256
            }
        ' >>"$derived_jsonl"
    fi
done

for record in "${output_extras[@]}"; do
    IFS=$'\t' read -r rel expected_bytes expected_sha extra <<<"$record"
    [[ -z "${extra:-}" ]] || die "invalid external output record"
    copy_external_output "$rel" "$expected_bytes" "$expected_sha" locked_output_extra
done

for rel in "${audio_outputs[@]}"; do
    is_safe_relative_path "$rel" || die "unsafe generated audio path: $rel"
    source_path_is_safe "$output_dir" "$rel" || die "missing or unsafe generated audio: $rel"
    source="$output_dir/$rel"
    [[ "$(stat -c %s -- "$source")" == "$generated_audio_bytes" &&
        "$(hash_file "$source")" == "$generated_audio_sha" ]] ||
        die "generated audio does not match build metadata: $rel"
    audio_json="$(ffprobe -v error \
        -show_entries stream=codec_name,sample_rate,channels:format=duration \
        -of json "$source")" || die "could not inspect generated audio: $rel"
    jq -e \
        --arg codec "$audio_codec" \
        --argjson sample_rate "$audio_sample_rate" \
        --argjson channels "$audio_channels" \
        --argjson duration "$audio_duration" '
        (.streams | type == "array" and length == 1) and
        .streams[0].codec_name == $codec and
        (.streams[0].sample_rate | tonumber) == $sample_rate and
        .streams[0].channels == $channels and
        ((.format.duration | tonumber) as $actual |
            ([($actual - $duration), ($duration - $actual)] | max) <= 0.001)
    ' <<<"$audio_json" >/dev/null || die "generated audio properties do not match the lock: $rel"
done
cmp -s -- "$output_dir/${audio_outputs[0]}" "$output_dir/${audio_outputs[1]}" ||
    die "generated audio outputs differ"
for rel in "${audio_outputs[@]}"; do
    copy_external_output "$rel" "$generated_audio_bytes" "$generated_audio_sha" generated_audio
done

jq -s '.' "$targets_jsonl" >"$staging/.targets.json"
jq -s '.' "$extras_jsonl" >"$staging/.extras.json"
jq -s '.' "$derived_jsonl" >"$staging/.derived-copies.json"
jq -n \
    --argjson schema 2 \
    --arg build_id "$build_id" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson provenance "$expected_provenance" \
    --slurpfile targets "$staging/.targets.json" \
    --slurpfile extras "$staging/.extras.json" \
    --slurpfile derived_copies "$staging/.derived-copies.json" '
    {
        schema: $schema,
        build_id: $build_id,
        created_at: $created_at,
        provenance: $provenance,
        targets: $targets[0],
        derived_copies: $derived_copies[0],
        extras: $extras[0]
    }
' >"$staging/manifest.json"
rm -- "$targets_jsonl" "$extras_jsonl" "$derived_jsonl" \
    "$staging/.targets.json" "$staging/.extras.json" "$staging/.derived-copies.json"

printf '%s\n' "$patchset_readme" >"$staging/README.txt"
verify_patchset_tree "$staging" "generated patchset"

if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -d "$destination" && ! -L "$destination" ]] ||
        die "destination changed to an unsafe file before publication: $destination"
    verify_patchset_tree "$destination" "existing destination patchset"
    [[ ! -e "$previous" && ! -L "$previous" ]] ||
        die "temporary previous-patchset path already exists: $previous"
    mv -T -- "$destination" "$previous"
fi
if ! mv -T -- "$staging" "$destination"; then
    if [[ -e "$previous" && ! -e "$destination" && ! -L "$destination" ]]; then
        if mv -T -- "$previous" "$destination"; then
            previous=""
        else
            echo "error: previous patchset was retained at: $previous" >&2
        fi
    fi
    die "could not publish patchset"
fi
staging=""
if [[ -n "$previous" && -e "$previous" ]]; then
    safe_remove_tree "$previous" "previous patchset" || true
fi
previous=""
echo "Patchset completed and verified: $destination"
