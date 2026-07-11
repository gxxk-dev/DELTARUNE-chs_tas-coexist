#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
version_file=${1:-"$root/versions/pc-v0.0.247-f3437be-260710.json"}

die() {
    echo "error: $*" >&2
    exit 1
}

hash_file() {
    local digest
    digest="$(sha256sum -- "$1")"
    printf '%s\n' "${digest%% *}"
}

is_safe_relative_path() {
    local path=$1 component
    local -a components=()

    [[ -n "$path" && "$path" != /* && "$path" != *\\* &&
        "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* &&
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

for command in git jq sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done

[[ -f "$version_file" && ! -L "$version_file" ]] ||
    die "version lock is not a regular file: $version_file"
version_file="$(readlink -f -- "$version_file")"

jq -e '
    def exact_keys($expected):
        (keys | sort) == ($expected | sort);
    def plain_string:
        type == "string" and length > 0 and
        (test("[\u0000-\u001f\u007f]") | not);
    def sha256:
        type == "string" and test("^[0-9a-f]{64}$");
    def commit:
        type == "string" and test("^[0-9a-f]{40}$");
    def positive_integer:
        type == "number" and . > 0 and floor == .;
    def safe_rel:
        plain_string and
        (startswith("/") | not) and
        (contains("\\") | not) and
        (contains("//") | not) and
        (endswith("/") | not) and
        (split("/") | all(.[]; . != "" and . != "." and . != ".."));
    def github_url:
        plain_string and
        test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\\.git|/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$");
    def locked_file:
        exact_keys(["bytes", "rel", "sha256"]) and
        (.rel | safe_rel) and
        (.bytes | positive_integer) and
        (.sha256 | sha256);
    def output_extra:
        exact_keys(["bytes", "rel", "sha256"]) and
        (.rel | safe_rel) and
        (.bytes | positive_integer) and
        (.sha256 | sha256);
    def unique_field($field):
        map(.[$field]) as $values |
        ($values | length) == ($values | unique | length);

    exact_keys([
        "adapters", "audio", "deltarune", "id", "output_extras",
        "platform", "schema", "tools", "upstreams"
    ]) and
    .schema == 2 and
    (.id | plain_string and test("^[a-z0-9][a-z0-9._-]*$") and . != "." and . != "..") and
    .platform == "windows-linux-proton" and

    (.deltarune | exact_keys(["files", "required_extras", "version"])) and
    .deltarune.version == "v0.0.247" and
    (.deltarune.files | type == "array" and length == 6 and unique_field("id") and unique_field("rel")) and
    ([.deltarune.files[].id] == ["main", "ch1", "ch2", "ch3", "ch4", "ch5"]) and
    ([.deltarune.files[].rel] == [
        "data.win",
        "chapter1_windows/data.win",
        "chapter2_windows/data.win",
        "chapter3_windows/data.win",
        "chapter4_windows/data.win",
        "chapter5_windows/data.win"
    ]) and
    all(.deltarune.files[];
        exact_keys(["bytes", "id", "keucher_sha256", "output_sha256", "rel", "sha256"]) and
        (.id | plain_string and test("^[a-z0-9][a-z0-9._-]*$")) and
        (.rel | safe_rel) and
        (.bytes | positive_integer) and
        (.sha256 | sha256) and
        (.keucher_sha256 | sha256) and
        (.output_sha256 | sha256)) and
    (.deltarune.required_extras |
        type == "array" and length > 0 and unique_field("rel")) and
    all(.deltarune.required_extras[]; locked_file) and

    (.upstreams | exact_keys(["deltarune_chinese", "keucher", "ump"])) and
    (.upstreams.keucher |
        exact_keys(["path", "source_commit", "url", "version"]) and
        (.version | plain_string) and (.path | safe_rel) and
        (.url | github_url and endswith(".git")) and (.source_commit | commit)) and
    (.upstreams.ump |
        exact_keys(["path", "source_commit", "source_sha256", "url", "version"]) and
        (.version | plain_string) and (.path | safe_rel) and
        (.url | github_url and endswith(".git")) and
        (.source_commit | commit) and (.source_sha256 | sha256)) and
    (.upstreams.deltarune_chinese |
        exact_keys(["commit", "path", "tag", "url"]) and
        (.tag | plain_string) and (.path | safe_rel) and
        (.url | github_url and endswith(".git")) and (.commit | commit)) and
    ([.upstreams[].path] | length == (unique | length)) and

    (.tools | exact_keys(["flips", "undertale_mod_cli"])) and
    (.tools.undertale_mod_cli |
        exact_keys([
            "archive", "bytes", "members", "reported_version", "sha256",
            "url", "version"
        ]) and
        (.version | plain_string) and (.reported_version | plain_string) and
        (.url | github_url) and
        (.archive | safe_rel and (contains("/") | not)) and
        (.bytes | positive_integer) and (.sha256 | sha256) and
        (.members | type == "array" and length > 0 and unique_field("rel")) and
        all(.members[]; locked_file)) and
    (.tools.undertale_mod_cli as $tool |
        $tool.url | endswith("/" + $tool.archive)) and
    (.tools.flips |
        exact_keys(["archive", "bytes", "members", "sha256", "url", "version"]) and
        (.version | plain_string) and (.url | github_url) and
        (.archive | safe_rel and (contains("/") | not)) and
        (.bytes | positive_integer) and (.sha256 | sha256) and
        (.members | type == "array" and length == 1 and unique_field("rel")) and
        all(.members[]; locked_file)) and
    ([.tools[].archive] | length == (unique | length)) and

    (.adapters | exact_keys(["deltarune_chinese", "keucher", "packages_lock"])) and
    all(.adapters[]; locked_file) and
    ([.adapters[].rel] | length == (unique | length)) and

    (.output_extras | type == "array" and length > 0 and unique_field("rel")) and
    all(.output_extras[]; output_extra) and
    (.audio |
        exact_keys([
            "channels", "codec", "duration", "fingerprint_algorithm",
            "fingerprint_min_similarity", "fingerprint_raw", "fingerprint_seconds",
            "outputs", "quality", "sample_rate", "source", "source_bytes",
            "source_sha256"
        ]) and
        (.source | safe_rel) and (.source_bytes | positive_integer) and
        (.source_sha256 | sha256) and
        .fingerprint_algorithm == "chromaprint-v1" and
        (.fingerprint_seconds | positive_integer) and
        (.fingerprint_min_similarity | type == "number" and . >= 0.9 and . <= 1) and
        (.fingerprint_raw | plain_string and test("^[0-9]+(,[0-9]+)+$") and
            (split(",") | length > 0 and all(.[];
                (tonumber | floor == . and . >= 0 and . <= 4294967295)))) and
        (.codec | plain_string) and
        (.sample_rate | positive_integer) and (.channels | positive_integer) and
        (.duration | type == "number" and . > 0) and
        (.quality | type == "number" and . >= -1 and . <= 10) and
        (.outputs | type == "array" and length == 2) and
        all(.outputs[]; safe_rel) and ((.outputs | unique | length) == 2)) and

    (([.deltarune.files[].rel] + [.output_extras[].rel] + .audio.outputs) as $outputs |
        ($outputs | length) == ($outputs | unique | length)) and
    (.deltarune.required_extras as $required |
        .output_extras as $extras |
        all($required[];
            . as $entry |
            any($extras[];
                .rel == $entry.rel and .bytes == $entry.bytes and .sha256 == $entry.sha256)))
' "$version_file" >/dev/null || die "invalid version lock: $version_file"

adapter_records="$(jq -er '
    .adapters | to_entries[] | [.key, .value.rel, (.value.bytes | tostring), .value.sha256] | @tsv
' "$version_file")" || die "could not read adapter records"
mapfile -t adapters <<<"$adapter_records"
[[ "${#adapters[@]}" -eq 3 ]] || die "version lock must define three adapters"
for record in "${adapters[@]}"; do
    IFS=$'\t' read -r adapter_name rel expected_bytes expected_sha extra <<<"$record"
    [[ -z "${extra:-}" && -n "$adapter_name" ]] || die "invalid adapter record"
    is_safe_relative_path "$rel" || die "unsafe adapter path: $rel"
    source_path_is_safe "$root" "$rel" || die "missing or unsafe locked adapter file: $rel"
    actual_bytes="$(stat -c %s -- "$root/$rel")"
    [[ "$actual_bytes" == "$expected_bytes" ]] || die "adapter size mismatch: $rel"
    actual_sha="$(hash_file "$root/$rel")"
    [[ "$actual_sha" == "$expected_sha" ]] || die "adapter SHA256 mismatch: $rel"
done

[[ -f "$root/.gitmodules" && ! -L "$root/.gitmodules" ]] ||
    die ".gitmodules is not a regular file"
submodule_records="$(jq -er '
    [
        (.upstreams.keucher | {name: .path, path, url, commit: .source_commit}),
        (.upstreams.ump | {name: .path, path, url, commit: .source_commit}),
        (.upstreams.deltarune_chinese | {name: .path, path, url, commit})
    ][] | [.name, .path, .url, .commit] | @tsv
' "$version_file")" || die "could not read submodule records"
mapfile -t submodules <<<"$submodule_records"
[[ "${#submodules[@]}" -eq 3 ]] || die "version lock must define three submodules"

declare -A expected_module_names=()
for record in "${submodules[@]}"; do
    IFS=$'\t' read -r name path expected_url expected_commit extra <<<"$record"
    [[ -z "${extra:-}" && "$name" == "$path" ]] || die "invalid submodule record"
    is_safe_relative_path "$path" || die "unsafe submodule path: $path"
    expected_module_names["$name"]=1

    path_values="$(git -C "$root" config -f .gitmodules --get-all "submodule.$name.path")" ||
        die "missing .gitmodules path for submodule $name"
    [[ "$path_values" != *$'\n'* && "$path_values" == "$path" ]] ||
        die ".gitmodules name/path mismatch: $name (expected $path)"
    url_values="$(git -C "$root" config -f .gitmodules --get-all "submodule.$name.url")" ||
        die "missing .gitmodules URL for submodule $name"
    [[ "$url_values" != *$'\n'* && "$url_values" == "$expected_url" ]] ||
        die "submodule URL mismatch: $path (expected $expected_url)"

    index_record="$(git -C "$root" ls-files -s -- "$path")" ||
        die "could not read submodule gitlink: $path"
    [[ -n "$index_record" && "$index_record" != *$'\n'* ]] ||
        die "submodule gitlink is missing or ambiguous: $path"
    IFS=$' \t' read -r mode actual_commit stage indexed_path <<<"$index_record"
    [[ "$mode" == 160000 && "$stage" == 0 && "$indexed_path" == "$path" ]] ||
        die "upstream path is not a stage-0 submodule gitlink: $path"
    [[ "$actual_commit" == "$expected_commit" ]] ||
        die "submodule gitlink mismatch: $path (expected $expected_commit, got $actual_commit)"
done

gitmodule_keys="$(git -C "$root" config -f .gitmodules --name-only --get-regexp '^submodule\.')" ||
    die "could not enumerate .gitmodules"
mapfile -t module_keys <<<"$gitmodule_keys"
declare -A module_key_counts=()
for key in "${module_keys[@]}"; do
    if [[ "$key" =~ ^submodule\.(.*)\.(path|url)$ ]]; then
        name=${BASH_REMATCH[1]}
        field=${BASH_REMATCH[2]}
    else
        die "unsupported .gitmodules key: $key"
    fi
    [[ -n "${expected_module_names[$name]+x}" ]] ||
        die "unexpected submodule section in .gitmodules: $name"
    count=${module_key_counts["$name.$field"]:-0}
    module_key_counts["$name.$field"]=$((count + 1))
done
for name in "${!expected_module_names[@]}"; do
    [[ "${module_key_counts["$name.path"]:-0}" -eq 1 ]] ||
        die ".gitmodules must define exactly one path for submodule $name"
    [[ "${module_key_counts["$name.url"]:-0}" -eq 1 ]] ||
        die ".gitmodules must define exactly one URL for submodule $name"
done

packages_lock_rel="$(jq -er '.adapters.packages_lock.rel' "$version_file")" ||
    die "could not read NuGet lock path"
source_path_is_safe "$root" "$packages_lock_rel" ||
    die "missing or unsafe NuGet lock: $packages_lock_rel"
packages_lock="$root/$packages_lock_rel"
jq -e '
    type == "object" and .version == 1 and
    (.dependencies | type == "object") and
    (.dependencies["net10.0"] | type == "object" and length > 0)
' "$packages_lock" >/dev/null || die "invalid NuGet lock: $packages_lock"

echo "version lock check passed"
