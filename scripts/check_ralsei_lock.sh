#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest=${1:-"$root/versions/ralsei-portraits-samuton-v1.json"}
version_file=${2:-"$root/versions/pc-v0.0.247-f3437be-260710.json"}

die() {
    echo "error: $*" >&2
    exit 1
}

hash_file() {
    local digest
    digest="$(sha256sum -- "$1")"
    printf '%s\n' "${digest%% *}"
}

for command in jq readlink sha256sum stat; do
    command -v "$command" >/dev/null || die "missing dependency: $command"
done
[[ -f "$manifest" && ! -L "$manifest" ]] || die "unsafe Ralsei lock: $manifest"
[[ -f "$version_file" && ! -L "$version_file" ]] || die "unsafe main version lock: $version_file"
manifest="$(readlink -f -- "$manifest")"
version_file="$(readlink -f -- "$version_file")"

expected_inputs="$(jq -ce '[.deltarune.files[1:][] | {
    chapter: .id, rel, input_sha256: .output_sha256
}]' "$version_file")" || die "could not read base output bindings"

jq -e --argjson expected_inputs "$expected_inputs" '
    def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
    def positive_integer: type == "number" and isfinite and floor == . and . > 0;
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def locked_file:
        exact(["rel", "bytes", "sha256"]) and
        (.rel | type == "string" and test("^scripts/[A-Za-z0-9_.-]+$")) and
        (.bytes | positive_integer) and (.sha256 | digest);
    def safe_rel:
        type == "string" and
        test("^Replace/ch[1-5]/[a-z0-9_]+(?:/[a-z0-9_]+_[0-9]+[.]png|[.]png)$");

    exact(["schema", "id", "archive", "importer", "outputs", "mapping_contract", "files"]) and
    .schema == 2 and .id == "ralsei-portraits-samuton-v1" and
    (.archive | exact(["filename", "format", "bytes", "sha256"]) and
        .filename == "Samuton.Ver Ralsei Portrait Texture Replacement Pack.7z" and
        .format == "7z" and (.bytes | positive_integer) and (.sha256 | digest)) and
    (.importer | exact(["wrapper", "script"]) and
        (.wrapper | locked_file) and (.script | locked_file) and
        .wrapper.rel == "scripts/apply_ralsei_portraits.sh" and
        .script.rel == "scripts/ralsei_portraits.csx") and
    (.outputs | type == "array" and length == 5) and
    ([.outputs[] | {chapter, rel, input_sha256}] == $expected_inputs) and
    all(.outputs[];
        exact(["chapter", "rel", "input_bytes", "input_sha256", "bytes", "sha256"]) and
        (.input_bytes | positive_integer) and (.input_sha256 | digest) and
        (.bytes | positive_integer) and (.sha256 | digest) and
        .sha256 != .input_sha256) and
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
        (.width | positive_integer and . <= 1024) and
        (.height | positive_integer and . <= 1024) and
        ($file.rel == ("Replace/" + $file.chapter + "/" + $file.sprite + "/" +
            $file.sprite + "_" + ($file.frame | tostring) + ".png") or
         ($file.frame == 0 and
            $file.rel == ("Replace/" + $file.chapter + "/" + $file.sprite + ".png")))) and
    ([.files[].rel] | length == (unique | length)) and
    ([.files[] | [.chapter, .sprite, .frame]] | length == (unique | length)) and
    ([.files | group_by(.chapter)[] | length] == [17, 50, 55, 69, 106]) and
    ([.files | group_by([.chapter, .sprite])[] |
        ([.[].frame] == [range(0; length)])] | all) and
    ([.files | group_by([.chapter, .sprite]) | length] == [22]) and
    (.files == (.files | sort_by(.chapter, .sprite, .frame)))
' "$manifest" >/dev/null || die "invalid Ralsei portrait lock: $manifest"

while IFS=$'\t' read -r rel expected_bytes expected_sha extra; do
    [[ -z "${extra:-}" ]] || die "invalid importer record: $rel"
    path="$root/$rel"
    [[ -f "$path" && ! -L "$path" && "$(stat -c %h -- "$path")" -eq 1 ]] ||
        die "missing or unsafe locked importer: $rel"
    [[ "$(stat -c %s -- "$path")" == "$expected_bytes" ]] ||
        die "importer size mismatch: $rel"
    [[ "$(hash_file "$path")" == "$expected_sha" ]] ||
        die "importer SHA256 mismatch: $rel"
done < <(jq -er '.importer[] | [.rel, (.bytes | tostring), .sha256] | @tsv' "$manifest")

echo "Ralsei portrait lock check passed"
