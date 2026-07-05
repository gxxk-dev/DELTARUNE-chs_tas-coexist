#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <data.win|output dir|DELTARUNE game dir> [...]" >&2
    echo "Example: $0 output" >&2
    echo "Example: $0 /path/to/DELTARUNE" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project=${DATAWIN_PROBE_PROJECT:-"$root/tools/DataWinProbe"}
tmp_dir="$(mktemp -d)"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

resolve_path() {
    local path=$1
    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi
    printf '%s\n' "$path"
}

add_target_file() {
    local file=$1
    [[ -f "$file" ]] || return 0
    printf '%s\n' "$file"
}

collect_targets() {
    local target
    target=$(resolve_path "$1")

    if [[ -f "$target" ]]; then
        add_target_file "$target"
        return 0
    fi
    if [[ ! -d "$target" ]]; then
        echo "Missing target: $target" >&2
        exit 1
    fi

    add_target_file "$target/data.win"
    add_target_file "$target/data_keucher.win"
    add_target_file "$target/chapter5_windows/data.win"
    add_target_file "$target/chapter5_windows/data_keucher.win"
}

patch_code() {
    local data_win=$1
    local code_name=$2
    local gml_file="$tmp_dir/${code_name}_$(basename "$(dirname "$data_win")").gml"

    dotnet run --project "$probe_project" -- decompile "$data_win" "$code_name" > "$gml_file"

    perl -0pi -e 's/draw_set_font\(2\);/draw_set_font(scr_84_get_font("main"));/g' "$gml_file"

    if rg -q 'draw_set_font\(2\);' "$gml_file" ||
        ! rg -q 'draw_set_font\(scr_84_get_font\("main"\)\);' "$gml_file"; then
        echo "Failed to patch evaluation font in $data_win:$code_name" >&2
        exit 1
    fi

    dotnet run --project "$probe_project" -- replace-code "$data_win" "$code_name" "$gml_file" "$data_win"
}

mapfile -t targets < <(
    for arg in "$@"; do
        collect_targets "$arg"
    done | awk '!seen[$0]++'
)

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "No chapter 5 data.win files found in targets" >&2
    exit 1
fi

for data_win in "${targets[@]}"; do
    echo "Patching $data_win"
    patch_code "$data_win" gml_Object_obj_round_evaluation_Draw_0
    patch_code "$data_win" gml_Object_obj_minigame_evaluation_Draw_0
done

echo "Applied chapter 5 rhythm evaluation font hotfix to ${#targets[@]} file(s)"
