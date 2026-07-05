#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <chapter5 data.win> [output data.win]" >&2
    echo "Example: $0 output/chapter5_windows/data.win" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project=${DATAWIN_PROBE_PROJECT:-"$root/tools/DataWinProbe"}
data_win=$1
output_win=${2:-$data_win}

if [[ "$data_win" != /* ]]; then
    data_win="$(pwd)/$data_win"
fi
if [[ "$output_win" != /* ]]; then
    output_win="$(pwd)/$output_win"
fi
if [[ ! -f "$data_win" ]]; then
    echo "Missing data.win: $data_win" >&2
    exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

if [[ "$data_win" != "$output_win" ]]; then
    cp "$data_win" "$output_win"
fi

patch_loading_guard() {
    local code_name=$1
    local gml_file="$tmp_dir/${code_name}.gml"

    dotnet run --project "$probe_project" -- decompile "$output_win" "$code_name" > "$gml_file"
    perl -0pi -e 's/if \((?:instance_exists\((?:obj_savestate_manager|1742)\) && )?obj_savestate_manager\.loading\)/if (instance_exists(obj_savestate_manager) && obj_savestate_manager.loading)/g' "$gml_file"
    if ! rg -q "instance_exists\\(obj_savestate_manager\\).*obj_savestate_manager\\.loading" "$gml_file"; then
        echo "Failed to patch loading guard in $code_name" >&2
        exit 1
    fi
    dotnet run --project "$probe_project" -- replace-code "$output_win" "$code_name" "$gml_file" "$output_win"
}

mod_init="$tmp_dir/gml_GlobalScript_mod_init.gml"
dotnet run --project "$probe_project" -- decompile "$output_win" gml_GlobalScript_mod_init > "$mod_init"
if ! rg -q "create_array\\([^)]*1742" "$mod_init"; then
    if ! rg -q "create_array\\(1735, 1736, 1738, 1740\\)" "$mod_init"; then
        echo "Expected Ch5 Keucher omnipresent instance list not found in mod_init" >&2
        exit 1
    fi
    perl -0pi -e 's/create_array\(1735, 1736, 1738, 1740\)/create_array(1735, 1736, 1738, 1740, 1742)/' "$mod_init"
fi
if ! rg -q "create_array\\([^)]*1742" "$mod_init"; then
    echo "Failed to add obj_savestate_manager to mod_init" >&2
    exit 1
fi
dotnet run --project "$probe_project" -- replace-code "$output_win" gml_GlobalScript_mod_init "$mod_init" "$output_win"

patch_loading_guard gml_Object_obj_pause_emulator_Create_0
patch_loading_guard gml_Object_obj_time_Create_0
patch_loading_guard gml_Object_obj_time_Step_1

echo "Applied Ch5 pause/savestate hotfix to $output_win"
