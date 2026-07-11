#!/usr/bin/env bash
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$root/versions/ralsei-portraits-samuton-v1.json"
csx="$root/scripts/ralsei_portraits.csx"
archive=""
output_dir=""
utmt=""
work_base="${TMPDIR:-/tmp}"
run_dir=""
source_archive_fd=""
archive_fd=""
input_fd=""
declare -a chapter_dirs=()
declare -a chapter_dir_identities=()

usage() {
    cat <<'EOF'
Usage: scripts/apply_ralsei_portraits.sh --archive FILE --output-dir DIR --utmt FILE [options]

Import the locally supplied Samuton Ralsei portrait replacement into an unpublished
Keucher + CHS staging output. The archive and generated output remain local.

Options:
  --archive FILE    Local 7z archive obtained by the user
  --output-dir DIR  Coexist output directory to modify
  --utmt FILE       Locked UndertaleModCli executable
  --work-dir DIR    Temporary directory parent
  -h, --help        Show this help
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

sha() {
    local digest
    digest="$(sha256sum -- "$1")"
    printf '%s\n' "${digest%% *}"
}

verify_locked_file() {
    local path=$1 expected_bytes=$2 expected_sha=$3 description=$4
    [[ -f "$path" && ! -L "$path" && "$(stat -c %h -- "$path")" -eq 1 ]] ||
        die "$description is missing or unsafe: $path"
    [[ "$(stat -c %s -- "$path")" == "$expected_bytes" &&
        "$(sha "$path")" == "$expected_sha" ]] ||
        die "$description does not match its lock: $path"
}

verify_locked_fd() {
    local path=$1 expected_bytes=$2 expected_sha=$3 description=$4
    [[ -f "$path" ]] || die "$description file descriptor is unsafe"
    [[ "$(stat -Lc %s -- "$path")" == "$expected_bytes" &&
        "$(sha "$path")" == "$expected_sha" ]] ||
        die "$description does not match its lock"
}

verify_png() {
    local path=$1 width=$2 height=$3 rel=$4 probe
    [[ -f "$path" && ! -L "$path" && "$(stat -c %h -- "$path")" -eq 1 &&
        "$(stat -c %s -- "$path")" -gt 0 ]] ||
        die "extracted portrait is empty or unsafe: $rel"
    probe="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=index,codec_name,width,height -of json -- "$path")" ||
        die "could not inspect extracted portrait: $rel"
    jq -e --argjson width "$width" --argjson height "$height" '
        (.streams | length) == 1 and
        .streams[0].index == 0 and .streams[0].codec_name == "png" and
        .streams[0].width == $width and .streams[0].height == $height
    ' <<<"$probe" >/dev/null || die "extracted portrait dimensions are invalid: $rel"
    ffmpeg -v error -xerror -nostdin -i "$path" -map 0:v:0 -frames:v 1 \
        -f null - </dev/null >/dev/null || die "could not decode extracted portrait: $rel"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "${source_archive_fd:-}" ]]; then
        exec {source_archive_fd}<&-
    fi
    if [[ -n "${archive_fd:-}" ]]; then
        exec {archive_fd}<&-
    fi
    if [[ -n "${input_fd:-}" ]]; then
        exec {input_fd}<&-
    fi
    if [[ -n "$run_dir" && -d "$run_dir" && ! -L "$run_dir" ]]; then
        rm -rf --one-file-system -- "$run_dir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while (($#)); do
    case "$1" in
        --archive)
            (($# >= 2)) || die "--archive requires a path"
            archive=$2
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
        --work-dir)
            (($# >= 2)) || die "--work-dir requires a path"
            work_base=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$archive" && -n "$output_dir" && -n "$utmt" ]] || {
    usage >&2
    exit 2
}
for command in chmod cmp cp ffmpeg ffprobe find jq mkdir mktemp mv readlink rm sha256sum stat; do
    command -v "$command" >/dev/null || die "missing dependency: $command"
done
if command -v 7zz >/dev/null; then
    seven_zip="$(command -v 7zz)"
elif command -v 7z >/dev/null; then
    seven_zip="$(command -v 7z)"
else
    die "missing dependency: 7zz or 7z"
fi

[[ -f "$manifest" && ! -L "$manifest" ]] || die "portrait manifest is missing or unsafe"
[[ -f "$csx" && ! -L "$csx" ]] || die "portrait importer is missing or unsafe"
[[ -f "$archive" && ! -L "$archive" && "$(stat -c %h -- "$archive")" -eq 1 ]] ||
    die "archive must be a regular single-linked file"
[[ -d "$output_dir" && ! -L "$output_dir" ]] || die "output directory is missing or unsafe"
[[ -f "$utmt" && ! -L "$utmt" && -x "$utmt" ]] || die "UTMT is missing or not executable"
[[ -d "$work_base" && ! -L "$work_base" ]] || die "work directory is missing or unsafe"

archive="$(readlink -f -- "$archive")"
output_dir="$(readlink -f -- "$output_dir")"
utmt="$(readlink -f -- "$utmt")"
work_base="$(readlink -f -- "$work_base")"

jq -e '
    def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
    def positive_integer: type == "number" and floor == . and . > 0;
    def sha256: type == "string" and test("^[0-9a-f]{64}$");
    def locked_file:
        exact(["rel", "bytes", "sha256"]) and
        (.rel | type == "string" and test("^scripts/[A-Za-z0-9_.-]+$")) and
        (.bytes | positive_integer) and (.sha256 | sha256);
    def safe_rel:
        type == "string" and test("^Replace/ch[1-5]/[a-z0-9_]+(?:/[a-z0-9_]+_[0-9]+[.]png|[.]png)$");
    exact(["schema", "id", "archive", "importer", "outputs", "mapping_contract", "files"]) and
    .schema == 2 and .id == "ralsei-portraits-samuton-v1" and
    (.archive | exact(["filename", "format", "bytes", "sha256"]) and
        .filename == "Samuton.Ver Ralsei Portrait Texture Replacement Pack.7z" and
        .format == "7z" and (.bytes | positive_integer) and (.sha256 | sha256)) and
    (.importer | exact(["wrapper", "script"]) and
        (.wrapper | locked_file) and (.script | locked_file) and
        .wrapper.rel == "scripts/apply_ralsei_portraits.sh" and
        .script.rel == "scripts/ralsei_portraits.csx") and
    (.outputs | type == "array" and length == 5) and
    ([.outputs[].chapter] == ["ch1", "ch2", "ch3", "ch4", "ch5"]) and
    ([.outputs[].rel] == [
        "chapter1_windows/data.win", "chapter2_windows/data.win",
        "chapter3_windows/data.win", "chapter4_windows/data.win",
        "chapter5_windows/data.win"
    ]) and
    all(.outputs[];
        exact(["chapter", "rel", "input_bytes", "input_sha256", "bytes", "sha256"]) and
        (.chapter | test("^ch[1-5]$")) and
        (.rel | test("^chapter[1-5]_windows/data[.]win$")) and
        (.input_bytes | positive_integer) and (.input_sha256 | sha256) and
        (.bytes | positive_integer) and (.sha256 | sha256)) and
    (.mapping_contract | exact([
        "root", "png_count", "chapter_ids", "sprite_group_count", "frame_index", "sort_order"
    ]) and .root == "Replace" and .png_count == 297 and .sprite_group_count == 22 and
        .chapter_ids == ["ch1", "ch2", "ch3", "ch4", "ch5"] and
        .frame_index == "zero-based-contiguous-per-chapter-and-sprite" and
        .sort_order == ["chapter-number", "sprite", "frame"]) and
    (.files | type == "array" and length == 297) and
    all(.files[]; . as $file |
        exact(["rel", "chapter", "sprite", "frame", "width", "height"]) and
        (.rel | safe_rel) and (.chapter | test("^ch[1-5]$")) and
        (.sprite | test("^[a-z0-9_]+$")) and
        (.frame | type == "number" and floor == . and . >= 0) and
        (.width | type == "number" and floor == . and . > 0 and . <= 1024) and
        (.height | type == "number" and floor == . and . > 0 and . <= 1024) and
        ($file.rel == ("Replace/" + $file.chapter + "/" + $file.sprite + "/" +
            $file.sprite + "_" + ($file.frame | tostring) + ".png") or
         ($file.frame == 0 and
            $file.rel == ("Replace/" + $file.chapter + "/" + $file.sprite + ".png")))) and
    ([.files[].rel] | length == (unique | length)) and
    ([.files[] | [.chapter, .sprite, .frame]] | length == (unique | length)) and
    ([.files | group_by([.chapter, .sprite])[] |
        ([.[].frame] == [range(0; length)])] | all) and
    ([.files | group_by([.chapter, .sprite]) | length] == [22])
' "$manifest" >/dev/null || die "invalid Ralsei portrait manifest"

while IFS=$'\t' read -r rel expected_bytes expected_sha; do
    verify_locked_file "$root/$rel" "$expected_bytes" "$expected_sha" "portrait importer"
done < <(jq -er '.importer[] | [.rel, (.bytes | tostring), .sha256] | @tsv' "$manifest")

expected_archive_bytes="$(jq -er '.archive.bytes' "$manifest")" || die "invalid archive size lock"
expected_archive_sha="$(jq -er '.archive.sha256' "$manifest")" || die "invalid archive hash lock"

run_dir="$(mktemp -d "$work_base/dr-ralsei-portraits.XXXXXX")"
chmod 700 -- "$run_dir"
assets="$run_dir/assets"
mkdir -m 700 -- "$assets"

exec {source_archive_fd}<"$archive" || die "could not open the Ralsei portrait archive"
source_archive_ref="/proc/$$/fd/$source_archive_fd"
[[ -f "$source_archive_ref" && "$(stat -Lc %h -- "$source_archive_ref")" -eq 1 &&
    "$(stat -Lc '%d:%i' -- "$archive")" == "$(stat -Lc '%d:%i' -- "$source_archive_ref")" ]] ||
    die "archive changed while it was opened"
archive_snapshot="$run_dir/archive.snapshot"
cp --reflink=never -- "$source_archive_ref" "$archive_snapshot" ||
    die "could not snapshot the Ralsei portrait archive"
exec {source_archive_fd}<&-
source_archive_fd=""
chmod 400 -- "$archive_snapshot"
exec {archive_fd}<"$archive_snapshot" || die "could not open the verified archive snapshot"
archive_ref="/proc/$$/fd/$archive_fd"
[[ -f "$archive_ref" && "$(stat -Lc %h -- "$archive_ref")" -eq 1 &&
    "$(stat -Lc '%d:%i' -- "$archive_snapshot")" == "$(stat -Lc '%d:%i' -- "$archive_ref")" ]] ||
    die "archive snapshot changed while it was opened"
rm -f -- "$archive_snapshot"
verify_locked_fd "$archive_ref" "$expected_archive_bytes" "$expected_archive_sha" \
    "Ralsei portrait archive"

LC_ALL=C "$seven_zip" t -bd -bb0 -sccUTF-8 \
    -p__RALSEI_ARCHIVE_MUST_NOT_BE_ENCRYPTED__ -- "$archive_ref" </dev/null >/dev/null ||
    die "Ralsei portrait archive test failed"

member_records="$(jq -er '.files[] | [.rel, (.width | tostring), (.height | tostring)] | @tsv' \
    "$manifest")" || die "could not read portrait member records"
member_count=0
while IFS=$'\t' read -r rel width height extra; do
    [[ -z "${extra:-}" && -n "$rel" ]] || die "invalid portrait member record"
    member_tmp="$(mktemp "$run_dir/.portrait.XXXXXX")"
    if ! LC_ALL=C "$seven_zip" x -so -bd -bb0 -sccUTF-8 -spd \
        -p__RALSEI_ARCHIVE_MUST_NOT_BE_ENCRYPTED__ -- "$archive_ref" "$rel" \
        </dev/null >"$member_tmp"; then
        die "could not extract locked portrait: $rel"
    fi
    verify_png "$member_tmp" "$width" "$height" "$rel"
    destination="$assets/$rel"
    mkdir -p -- "${destination%/*}"
    mv -T -- "$member_tmp" "$destination"
    ((member_count += 1))
done <<<"$member_records"
[[ "$member_count" -eq 297 ]] || die "invalid extracted portrait count"

expected_tree="$run_dir/expected-tree.txt"
actual_tree="$run_dir/actual-tree.txt"
{
    while IFS= read -r rel; do
        printf 'f %s\n' "$rel"
        parent=${rel%/*}
        while [[ "$parent" != "$rel" ]]; do
            printf 'd %s\n' "$parent"
            rel=$parent
            parent=${rel%/*}
        done
    done < <(jq -er '.files[].rel' "$manifest")
} | LC_ALL=C sort -u > "$expected_tree"
find "$assets" -xdev -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort > "$actual_tree"
cmp -s -- "$expected_tree" "$actual_tree" || die "extracted portrait tree is not exact"
linked="$(find "$assets" -xdev -type f ! -links 1 -print -quit)"
[[ -z "$linked" ]] || die "extracted portrait tree contains a hard-linked file: $linked"

for chapter in 1 2 3 4 5; do
    chapter_dir="$output_dir/chapter${chapter}_windows"
    [[ -d "$chapter_dir" && ! -L "$chapter_dir" &&
        "$(readlink -f -- "$chapter_dir")" == "$chapter_dir" ]] ||
        die "coexist chapter directory is missing or unsafe: chapter${chapter}_windows"
    chapter_dirs[$chapter]="$chapter_dir"
    chapter_dir_identities[$chapter]="$(stat -Lc '%d:%i' -- "$chapter_dir")"
done

for chapter in 1 2 3 4 5; do
    output_record="$(jq -er --arg chapter "ch$chapter" \
        '.outputs[] | select(.chapter == $chapter) | [.rel, (.input_bytes | tostring), .input_sha256, (.bytes | tostring), .sha256] | @tsv' \
        "$manifest")" || die "could not read output lock for chapter $chapter"
    IFS=$'\t' read -r rel input_bytes input_sha output_bytes output_sha extra <<<"$output_record"
    [[ -z "${extra:-}" && -n "$output_sha" ]] || die "invalid output lock for chapter $chapter"
    input="${chapter_dirs[$chapter]}/data.win"
    candidate="$run_dir/ch${chapter}.win"
    [[ "$(stat -Lc '%d:%i' -- "${chapter_dirs[$chapter]}")" == "${chapter_dir_identities[$chapter]}" ]] ||
        die "coexist chapter directory changed before import: chapter${chapter}_windows"
    [[ -f "$input" && ! -L "$input" ]] || die "coexist input is missing or unsafe: $rel"
    exec {input_fd}<"$input" || die "could not open coexist input: $rel"
    input_ref="/proc/$$/fd/$input_fd"
    [[ -f "$input_ref" && "$(stat -Lc %h -- "$input_ref")" -eq 1 &&
        "$(stat -Lc '%d:%i' -- "$input")" == "$(stat -Lc '%d:%i' -- "$input_ref")" ]] ||
        die "coexist input changed while it was opened: $rel"
    verify_locked_fd "$input_ref" "$input_bytes" "$input_sha" "coexist input"
    input_mode="$(stat -Lc %a -- "$input_ref")"
    RALSEI_PORTRAITS_ACTION=import \
    RALSEI_PORTRAITS_CHAPTER="ch$chapter" \
    RALSEI_PORTRAITS_MANIFEST="$manifest" \
    RALSEI_PORTRAITS_ROOT="$assets" \
        "$utmt" load "$input_ref" -s "$csx" -o "$candidate"
    [[ -f "$candidate" && ! -L "$candidate" ]] || die "UTMT did not create: $rel"
    chmod "$input_mode" -- "$candidate"
    RALSEI_PORTRAITS_ACTION=verify \
    RALSEI_PORTRAITS_CHAPTER="ch$chapter" \
    RALSEI_PORTRAITS_MANIFEST="$manifest" \
    RALSEI_PORTRAITS_ROOT="$assets" \
        "$utmt" load "$candidate" -s "$csx"
    verify_locked_file "$candidate" "$output_bytes" "$output_sha" "Ralsei variant output"
    exec {input_fd}<&-
    input_fd=""
done

for chapter in 1 2 3 4 5; do
    rel="chapter${chapter}_windows/data.win"
    [[ -d "${chapter_dirs[$chapter]}" && ! -L "${chapter_dirs[$chapter]}" &&
        "$(stat -Lc '%d:%i' -- "${chapter_dirs[$chapter]}")" == "${chapter_dir_identities[$chapter]}" ]] ||
        die "coexist chapter directory changed before publication: chapter${chapter}_windows"
    mv -f -- "$run_dir/ch${chapter}.win" "${chapter_dirs[$chapter]}/data.win"
done

echo "Ralsei portrait replacement imported and verified: $output_dir"
