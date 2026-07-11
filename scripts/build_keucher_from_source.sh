#!/usr/bin/env bash
set -euo pipefail

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
game_dir=""
output_dir=""
utmt="${UTMT_CLI:-}"
keucher_dir="$root/upstream/keucher-mod"
ump_dir="$root/upstream/UMP"
adapter="$root/adapters/keucher-f3437be-linux.patch"
version_file="$root/versions/pc-v0.0.247-f3437be-260710.json"
keep_work=0
run_dir=""
run_parent=""
staging_dir=""
staging_parent=""
output_parent=""
output_parent_identity=""
output_lock_fd=""
current_uid=$EUID

usage() {
    cat <<'EOF'
Usage: scripts/build_keucher_from_source.sh --game-dir DIR --output-dir DIR --utmt FILE [options]

Build the six Keucher Mod data.win files from pinned source commits. Inputs are
read-only; the locked commits and adapter are exported to a private workspace.
The output directory must not exist, and its parent directory must already exist.

Required:
  --game-dir DIR       Clean DELTARUNE directory
  --output-dir DIR     New directory for the six built data.win files
  --utmt FILE          UndertaleModCli 0.9.1.1 executable

Options:
  --keucher-dir DIR    Keucher Git repository (default: upstream/keucher-mod)
  --ump-dir DIR        UMP Git repository (default: upstream/UMP)
  --adapter FILE       Linux adapter patch
  --version-file FILE  Input/Keucher commit lock
  --keep-work          Keep the temporary source tree and logs
  -h, --help           Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

note() {
    printf '\n==> %s\n' "$*"
}

path_is_at_or_below() {
    local path=$1 base=$2
    [[ "$path" == "$base" || "$base" == / || "$path" == "$base/"* ]]
}

path_is_strictly_below() {
    local path=$1 base=$2
    [[ "$path" != "$base" ]] && path_is_at_or_below "$path" "$base"
}

reject_control_characters() {
    local path=$1 label=$2
    [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* &&
        "$path" != *$'\t'* ]] || die "$label contains unsafe control characters"
}

canonical_directory() {
    local path=$1 label=$2 physical
    reject_control_characters "$path" "$label"
    [[ -d "$path" ]] || die "$label does not exist: $path"
    physical="$(cd -P -- "$path" && pwd -P)" || die "could not resolve $label: $path"
    [[ -d "$physical" && ! -L "$physical" ]] || die "$label is not a physical directory: $path"
    printf '%s\n' "$physical"
}

canonical_file() {
    local path=$1 label=$2 physical
    reject_control_characters "$path" "$label"
    [[ -f "$path" ]] || die "$label does not exist: $path"
    physical="$(readlink -e -- "$path")" || die "could not resolve $label: $path"
    [[ -f "$physical" && ! -L "$physical" ]] || die "$label is not a physical regular file: $path"
    printf '%s\n' "$physical"
}

reject_overlap() {
    local first=$1 first_label=$2 second=$3 second_label=$4
    if path_is_at_or_below "$first" "$second" || path_is_at_or_below "$second" "$first"; then
        die "$first_label overlaps $second_label ($first, $second)"
    fi
}

first_mount_at_or_below() {
    local base=$1 include_base=$2 records encoded target physical
    records="$(findmnt --json --output TARGET | jq -er '
        .. | objects | .target? | select(type == "string") | @base64
    ')" || return 2
    while IFS= read -r encoded; do
        [[ -n "$encoded" ]] || continue
        target="$(printf '%s' "$encoded" | base64 --decode)" || return 2
        physical="$(readlink -f -- "$target" 2>/dev/null || true)"
        [[ -n "$physical" ]] || continue
        if [[ "$include_base" == 1 ]]; then
            if path_is_at_or_below "$physical" "$base"; then
                printf '%s\n' "$physical"
                return 0
            fi
        elif path_is_strictly_below "$physical" "$base"; then
            printf '%s\n' "$physical"
            return 0
        fi
    done <<<"$records"
    return 1
}

assert_no_descendant_mounts() {
    local path=$1 label=$2 found status
    if found="$(first_mount_at_or_below "$path" 0)"; then
        die "$label contains a nested mount point: $found"
    else
        status=$?
        ((status == 1)) || die "could not inspect mount points for $label"
    fi
}

assert_no_mounts_in_private_tree() {
    local path=$1 label=$2 found status
    if found="$(first_mount_at_or_below "$path" 1)"; then
        die "$label is or contains a mount point: $found"
    else
        status=$?
        ((status == 1)) || die "could not inspect mount points for $label"
    fi
}

validate_mutable_parent() {
    local path=$1 label=$2 owner mode mode_value
    [[ -d "$path" && ! -L "$path" ]] || die "$label is not a physical directory: $path"
    [[ -w "$path" && -x "$path" ]] || die "$label is not writable and searchable: $path"
    owner="$(stat -c %u -- "$path")"
    mode="$(stat -c %a -- "$path")"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "could not validate permissions for $label: $path"
    mode_value=$((8#$mode))
    if ((mode_value & 0022)); then
        ((mode_value & 01000)) ||
            die "$label is group/world-writable without the sticky bit: $path"
    fi
    if [[ "$owner" != "$current_uid" ]]; then
        ((mode_value & 01000)) || die "$label is not owned by the current user: $path"
    fi
}

validate_private_directory() {
    local path=$1 parent=$2 label=$3 physical owner mode links device
    [[ -d "$path" && ! -L "$path" ]] || die "$label is not a physical directory: $path"
    physical="$(readlink -e -- "$path")" || die "could not resolve $label: $path"
    [[ "$physical" == "$path" ]] || die "$label escaped its requested location: $path"
    [[ "$(dirname -- "$physical")" == "$parent" ]] || die "$label has an unexpected parent: $path"
    owner="$(stat -c %u -- "$physical")"
    mode="$(stat -c %a -- "$physical")"
    links="$(stat -c %h -- "$physical")"
    device="$(stat -c %d -- "$physical")"
    [[ "$owner" == "$current_uid" && "$mode" == 700 && "$links" -ge 2 ]] ||
        die "$label has unsafe ownership, permissions, or link count: $path"
    [[ "$device" == "$(stat -c %d -- "$parent")" ]] ||
        die "$label is not on the same filesystem as its parent: $path"
    assert_no_mounts_in_private_tree "$physical" "$label"
}

validate_parent_identity() {
    local actual
    [[ -d "$output_parent" && ! -L "$output_parent" ]] ||
        die "output parent changed during the build: $output_parent"
    actual="$(stat -c '%d:%i:%u' -- "$output_parent")"
    [[ "$actual" == "$output_parent_identity" ]] ||
        die "output parent changed during the build: $output_parent"
}

safe_remove_private_tree() {
    local path=$1 parent=$2 label=$3 found status physical
    [[ -n "$path" ]] || return 0
    if [[ -L "$path" || ! -d "$path" ]]; then
        echo "error: refusing to remove unsafe $label: $path" >&2
        return 1
    fi
    physical="$(readlink -e -- "$path" 2>/dev/null || true)"
    if [[ "$physical" != "$path" || "$(dirname -- "$path")" != "$parent" ||
        "$(stat -c %u -- "$path" 2>/dev/null || true)" != "$current_uid" ]]; then
        echo "error: refusing to remove unsafe $label: $path" >&2
        return 1
    fi
    if found="$(first_mount_at_or_below "$path" 1)"; then
        echo "error: refusing to remove $label with a mount point at $found" >&2
        return 1
    else
        status=$?
        if ((status != 1)); then
            echo "error: could not inspect mount points before removing $label: $path" >&2
            return 1
        fi
    fi
    rm -rf --one-file-system -- "$path"
}

sha() {
    sha256sum "$1" | awk '{print $1}'
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
        --utmt)
            (($# >= 2)) || die "--utmt requires a path"
            utmt=$2
            shift 2
            ;;
        --keucher-dir)
            (($# >= 2)) || die "--keucher-dir requires a path"
            keucher_dir=$2
            shift 2
            ;;
        --ump-dir)
            (($# >= 2)) || die "--ump-dir requires a path"
            ump_dir=$2
            shift 2
            ;;
        --adapter)
            (($# >= 2)) || die "--adapter requires a path"
            adapter=$2
            shift 2
            ;;
        --version-file)
            (($# >= 2)) || die "--version-file requires a path"
            version_file=$2
            shift 2
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
[[ -n "$output_dir" ]] || { usage >&2; exit 2; }
[[ -n "$utmt" ]] || { usage >&2; exit 2; }

for command in awk base64 basename cp dirname find findmnt flock git jq mkdir \
    mktemp mv patch readlink rm sed sha256sum sort stat tail tar xargs; do
    command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done

root="$(canonical_directory "$root" "repository root")"
game_dir="$(canonical_directory "$game_dir" "game directory")"
keucher_dir="$(canonical_directory "$keucher_dir" "Keucher repository")"
ump_dir="$(canonical_directory "$ump_dir" "UMP repository")"
adapter="$(canonical_file "$adapter" "adapter patch")"
version_file="$(canonical_file "$version_file" "version lock")"
utmt="$(canonical_file "$utmt" "UndertaleModCli")"
[[ -x "$utmt" ]] || die "UndertaleModCli is not executable: $utmt"

tmp_dir="$(canonical_directory "${TMPDIR:-/tmp}" "TMPDIR")"
validate_mutable_parent "$tmp_dir" "TMPDIR"

output_argument=$output_dir
reject_control_characters "$output_argument" "output path"
[[ ! -e "$output_argument" && ! -L "$output_argument" ]] ||
    die "output path already exists: $output_argument"
output_name="$(basename -- "$output_argument")"
[[ -n "$output_name" && "$output_name" != . && "$output_name" != .. &&
    "$output_name" != .keucher-source-build-locks ]] || die "output path has an unsafe final component"
output_parent_argument="$(dirname -- "$output_argument")"
output_parent="$(canonical_directory "$output_parent_argument" "output parent")"
validate_mutable_parent "$output_parent" "output parent"
output_dir="$output_parent/$output_name"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || die "output path already exists: $output_dir"

reject_overlap "$game_dir" "game directory" "$root" "repository root"
reject_overlap "$game_dir" "game directory" "$keucher_dir" "Keucher repository"
reject_overlap "$game_dir" "game directory" "$ump_dir" "UMP repository"
reject_overlap "$keucher_dir" "Keucher repository" "$ump_dir" "UMP repository"
reject_overlap "$output_dir" "output path" "$root" "repository root"
reject_overlap "$output_dir" "output path" "$game_dir" "game directory"
reject_overlap "$output_dir" "output path" "$keucher_dir" "Keucher repository"
reject_overlap "$output_dir" "output path" "$ump_dir" "UMP repository"
reject_overlap "$output_dir" "output path" "$adapter" "adapter patch"
reject_overlap "$output_dir" "output path" "$version_file" "version lock"
reject_overlap "$output_dir" "output path" "$utmt" "UndertaleModCli"
if path_is_at_or_below "$tmp_dir" "$root"; then
    die "TMPDIR is inside the repository root ($tmp_dir, $root)"
fi
if path_is_at_or_below "$tmp_dir" "$game_dir"; then
    die "TMPDIR is inside the game directory ($tmp_dir, $game_dir)"
fi
if path_is_at_or_below "$tmp_dir" "$keucher_dir"; then
    die "TMPDIR is inside the Keucher repository ($tmp_dir, $keucher_dir)"
fi
if path_is_at_or_below "$tmp_dir" "$ump_dir"; then
    die "TMPDIR is inside the UMP repository ($tmp_dir, $ump_dir)"
fi

assert_no_descendant_mounts "$root" "repository root"
assert_no_descendant_mounts "$game_dir" "game directory"
if ! path_is_at_or_below "$keucher_dir" "$root"; then
    assert_no_descendant_mounts "$keucher_dir" "Keucher repository"
fi
if ! path_is_at_or_below "$ump_dir" "$root"; then
    assert_no_descendant_mounts "$ump_dir" "UMP repository"
fi

output_parent_identity="$(stat -c '%d:%i:%u' -- "$output_parent")"
lock_dir="$output_parent/.keucher-source-build-locks"
if [[ ! -e "$lock_dir" && ! -L "$lock_dir" ]]; then
    mkdir -m 700 -- "$lock_dir" 2>/dev/null || true
fi
[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || die "output lock directory is unsafe: $lock_dir"
[[ "$(stat -c %u -- "$lock_dir")" == "$current_uid" &&
    "$(stat -c %a -- "$lock_dir")" == 700 &&
    "$(stat -c %h -- "$lock_dir")" -ge 2 ]] ||
    die "output lock directory has unsafe ownership, permissions, or link count: $lock_dir"
[[ "$(readlink -e -- "$lock_dir")" == "$lock_dir" ]] ||
    die "output lock directory escaped its requested location: $lock_dir"
assert_no_mounts_in_private_tree "$lock_dir" "output lock directory"

lock_id="$(printf '%s' "$output_dir" | sha256sum | awk '{print $1}')"
lock_file="$lock_dir/$lock_id.lock"
if [[ -e "$lock_file" || -L "$lock_file" ]]; then
    [[ -f "$lock_file" && ! -L "$lock_file" &&
        "$(stat -c %u -- "$lock_file")" == "$current_uid" &&
        "$(stat -c %a -- "$lock_file")" == 600 &&
        "$(stat -c %h -- "$lock_file")" == 1 ]] ||
        die "output lock is not a private, single-linked regular file: $lock_file"
fi
umask 077
exec {output_lock_fd}<>"$lock_file"
[[ -f "$lock_file" && ! -L "$lock_file" &&
    "$(stat -c %u -- "$lock_file")" == "$current_uid" &&
    "$(stat -c %a -- "$lock_file")" == 600 &&
    "$(stat -c %h -- "$lock_file")" == 1 &&
    "$(stat -c '%d:%i' -- "$lock_file")" == "$(stat -Lc '%d:%i' -- "/proc/self/fd/$output_lock_fd")" ]] ||
    die "output lock changed while it was opened: $lock_file"
flock -n "$output_lock_fd" || die "another Keucher build is using the output path: $output_dir"
validate_parent_identity
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || die "output path already exists: $output_dir"

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$staging_dir" ]]; then
        if ! safe_remove_private_tree "$staging_dir" "$staging_parent" "staging directory"; then
            ((status == 0)) && status=1
        fi
    fi
    if [[ -n "$run_dir" ]]; then
        if ((keep_work)); then
            echo "build workspace kept at: $run_dir" >&2
        else
            if ! safe_remove_private_tree "$run_dir" "$run_parent" "build workspace"; then
                ((status == 0)) && status=1
            fi
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_parent=$tmp_dir
run_dir="$(mktemp -d "$run_parent/keucher-source-build.XXXXXX")"
validate_private_directory "$run_dir" "$run_parent" "build workspace"
reject_overlap "$run_dir" "build workspace" "$root" "repository root"
reject_overlap "$run_dir" "build workspace" "$game_dir" "game directory"
reject_overlap "$run_dir" "build workspace" "$keucher_dir" "Keucher repository"
reject_overlap "$run_dir" "build workspace" "$ump_dir" "UMP repository"
reject_overlap "$run_dir" "build workspace" "$output_dir" "output path"

version_snapshot="$run_dir/version-lock.json"
adapter_snapshot="$run_dir/keucher-adapter.patch"
version_sha="$(sha "$version_file")"
adapter_sha="$(sha "$adapter")"
cp --preserve=mode,timestamps -- "$version_file" "$version_snapshot"
cp --preserve=mode,timestamps -- "$adapter" "$adapter_snapshot"
[[ "$(sha "$version_snapshot")" == "$version_sha" && "$(sha "$version_file")" == "$version_sha" ]] ||
    die "version lock changed while it was copied"
[[ "$(sha "$adapter_snapshot")" == "$adapter_sha" && "$(sha "$adapter")" == "$adapter_sha" ]] ||
    die "adapter patch changed while it was copied"
version_file=$version_snapshot
adapter=$adapter_snapshot

expected_keucher_commit="$(jq -er '.upstreams.keucher.source_commit' "$version_file")" ||
    die "Keucher source commit is not present in version lock"
[[ "$expected_keucher_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid locked Keucher source commit"
GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    git -C "$keucher_dir" cat-file -e "$expected_keucher_commit^{commit}" 2>/dev/null ||
    die "locked Keucher source commit is unavailable: $expected_keucher_commit"

expected_ump_commit="$(jq -er '.upstreams.ump.source_commit' "$version_file")" ||
    die "UMP source commit is not present in version lock"
expected_ump_sha256="$(jq -er '.upstreams.ump.source_sha256' "$version_file")" ||
    die "UMP source hash is not present in version lock"
[[ "$expected_ump_commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid locked UMP source commit"
[[ "$expected_ump_sha256" =~ ^[0-9a-f]{64}$ ]] || die "invalid locked UMP source hash"
GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    git -C "$ump_dir" cat-file -e "$expected_ump_commit^{commit}" 2>/dev/null ||
    die "locked UMP source commit is unavailable: $expected_ump_commit"

verify_input() {
    local rel=$1 destination expected_sha expected_bytes path physical actual_sha actual_bytes
    expected_sha="$(jq -er --arg rel "$rel" '.deltarune.files[] | select(.rel == $rel) | .sha256' "$version_file")" ||
        die "input is not present in version lock: $rel"
    expected_bytes="$(jq -er --arg rel "$rel" '.deltarune.files[] | select(.rel == $rel) | .bytes' "$version_file")" ||
        die "input size is not present in version lock: $rel"
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ && "$expected_bytes" =~ ^[0-9]+$ ]] ||
        die "invalid input lock for $rel"
    path="$game_dir/$rel"
    [[ -f "$path" && ! -L "$path" ]] || die "missing regular game input: $path"
    physical="$(readlink -e -- "$path")" || die "could not resolve game input: $path"
    [[ "$physical" == "$path" ]] || die "game input traverses a symbolic link: $path"
    actual_bytes="$(stat -c %s -- "$path")"
    [[ "$actual_bytes" == "$expected_bytes" ]] ||
        die "size mismatch for $rel (expected $expected_bytes, got $actual_bytes)"
    actual_sha="$(sha "$path")"
    [[ "$actual_sha" == "$expected_sha" ]] ||
        die "SHA256 mismatch for $rel (expected $expected_sha, got $actual_sha)"

    destination="$run_dir/inputs/$rel"
    mkdir -p -- "$(dirname -- "$destination")"
    cp --reflink=auto --preserve=mode,timestamps -- "$path" "$destination"
    [[ -f "$destination" && ! -L "$destination" && "$(stat -c %h -- "$destination")" == 1 &&
        "$(stat -c %s -- "$destination")" == "$expected_bytes" &&
        "$(sha "$destination")" == "$expected_sha" &&
        "$(stat -c %s -- "$path")" == "$expected_bytes" && "$(sha "$path")" == "$expected_sha" ]] ||
        die "game input changed while it was copied: $rel"
}

assert_no_descendant_mounts "$game_dir" "game directory"
for rel in \
    data.win \
    chapter1_windows/data.win \
    chapter2_windows/data.win \
    chapter3_windows/data.win \
    chapter4_windows/data.win \
    chapter5_windows/data.win; do
    verify_input "$rel"
done

"$utmt" --version >/dev/null || die "UndertaleModCli could not start: $utmt"

source_dir="$run_dir/keucher-mod"
mkdir -- "$source_dir"
assert_no_descendant_mounts "$root" "repository root"
if ! path_is_at_or_below "$keucher_dir" "$root"; then
    assert_no_descendant_mounts "$keucher_dir" "Keucher repository"
fi
if ! path_is_at_or_below "$ump_dir" "$root"; then
    assert_no_descendant_mounts "$ump_dir" "UMP repository"
fi
GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    git -C "$keucher_dir" archive "$expected_keucher_commit" |
    tar --no-same-owner --no-same-permissions -xf - -C "$source_dir"

mkdir -p -- "$source_dir/src/ump"
GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 \
    git -C "$ump_dir" show "$expected_ump_commit:src/ump.csx" > "$source_dir/src/ump/ump.csx"
actual_ump_sha256="$(sha "$source_dir/src/ump/ump.csx")"
[[ "$actual_ump_sha256" == "$expected_ump_sha256" ]] ||
    die "UMP source mismatch (expected $expected_ump_sha256, got $actual_ump_sha256)"

note "Applying Keucher Linux adapter"
sed -i 's/\r$//' "$source_dir/src/mod/sprites/ImportGraphics/ImportGraphics.csx"
patch --batch --forward --fuzz=0 --directory="$source_dir" -p1 < "$adapter"

staging_parent=$output_parent
staging_dir="$(mktemp -d "$staging_parent/.keucher-output.XXXXXX")"
validate_private_directory "$staging_dir" "$staging_parent" "staging directory"
reject_overlap "$staging_dir" "staging directory" "$root" "repository root"
reject_overlap "$staging_dir" "staging directory" "$game_dir" "game directory"
reject_overlap "$staging_dir" "staging directory" "$keucher_dir" "Keucher repository"
reject_overlap "$staging_dir" "staging directory" "$ump_dir" "UMP repository"

build_one() {
    local id=$1 rel=$2 script=$3 destination log invocation_dir expected_sha actual_sha
    destination="$staging_dir/$rel"
    log="$run_dir/$id.log"
    invocation_dir="$run_dir/cwd/$id"
    mkdir -p -- "$(dirname -- "$destination")"
    mkdir -p -- "$invocation_dir"
    note "Building $id"
    if ! (cd -P -- "$invocation_dir" &&
        "$utmt" load "$run_dir/inputs/$rel" -s "$source_dir/src/$script" -o "$destination") >"$log" 2>&1; then
        echo "UndertaleModCli log for $id:" >&2
        tail -n 80 "$log" >&2
        die "Keucher build failed for $id"
    fi
    [[ -s "$destination" && ! -L "$destination" && "$(stat -c %h -- "$destination")" == 1 ]] ||
        die "Keucher build produced an unsafe or empty output for $id"
    expected_sha="$(jq -er --arg rel "$rel" '.deltarune.files[] | select(.rel == $rel) | .keucher_sha256' "$version_file")" ||
        die "Keucher output hash is not present in version lock: $rel"
    actual_sha="$(sha "$destination")"
    [[ "$actual_sha" == "$expected_sha" ]] ||
        die "Keucher output hash mismatch for $rel (expected $expected_sha, got $actual_sha)"
    printf '%-14s %s  %s\n' "$id" "$actual_sha" "$rel"
}

build_one chapter-select data.win ChapterSelect.csx
build_one chapter-1 chapter1_windows/data.win Chapter1.csx
build_one chapter-2 chapter2_windows/data.win Chapter2.csx
build_one chapter-3 chapter3_windows/data.win Chapter3.csx
build_one chapter-4 chapter4_windows/data.win Chapter4.csx
build_one chapter-5 chapter5_windows/data.win Chapter5.csx

(
    assert_no_mounts_in_private_tree "$staging_dir" "staging directory"
    cd -P -- "$staging_dir"
    find . -type f -name data.win -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

validate_parent_identity
validate_private_directory "$staging_dir" "$staging_parent" "staging directory"
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] ||
    die "output path appeared before publication: $output_dir"
staging_identity="$(stat -c '%d:%i:%u' -- "$staging_dir")"
mv -T -n -- "$staging_dir" "$output_dir"
[[ ! -e "$staging_dir" && ! -L "$staging_dir" && -d "$output_dir" && ! -L "$output_dir" &&
    "$(stat -c '%d:%i:%u' -- "$output_dir")" == "$staging_identity" ]] ||
    die "output publication was not an atomic, no-replace rename: $output_dir"
staging_dir=""
note "Keucher source build complete: $output_dir"
