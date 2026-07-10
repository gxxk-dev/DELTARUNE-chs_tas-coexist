#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <DeltaruneChinese workspace> <Keucher baseline dir>" >&2
    echo "Example: $0 work/DeltaruneChinese-keucher-v5.10.7/workspace build/keucher-v5.10.7" >&2
    exit 2
fi

workspace=$1
keucher_dir=$2
if [[ "$workspace" != /* ]]; then
    workspace="$(pwd)/$workspace"
fi
if [[ "$keucher_dir" != /* ]]; then
    keucher_dir="$(pwd)/$keucher_dir"
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

probe_project=${DATAWIN_PROBE_PROJECT:-tools/DataWinProbe}
savestate_code_name=gml_Object_obj_savestate_manager_Create_0
readable_step_code_name=gml_Object_obj_readable_room1_Step_0

for chapter in 1 2 3 4 5; do
    data_win="$keucher_dir/chapter${chapter}_windows/data.win"
    import_dir="$workspace/ch${chapter}/imports/code"
    if [[ ! -f "$data_win" ]]; then
        echo "Missing Keucher baseline: $data_win" >&2
        exit 1
    fi
    if [[ ! -d "$import_dir" ]]; then
        echo "Missing import dir: $import_dir" >&2
        exit 1
    fi

    manager_file="$import_dir/${savestate_code_name}.gml"
    manager_tmp="${manager_file}.baseline.tmp"
    dotnet run --project "$probe_project" -- decompile "$data_win" "$savestate_code_name" > "$manager_tmp"
    if ! rg -q "function decode_data_type\\(" "$manager_tmp" ||
        ! rg -q "game_display_name" "$manager_tmp" ||
        ! rg -q "asset_get_index\\(arg0\\.const_func\\)" "$manager_tmp"; then
        echo "Expected Keucher savestate v2 manager not found for chapter $chapter" >&2
        rm -f "$manager_tmp"
        exit 1
    fi
    rm -f "$manager_tmp"

    if [[ -f "$manager_file" ]] && rg -q "decode_var_info|playing_sounds|new arg0\\.const_func" "$manager_file"; then
        rm -f "$manager_file"
        echo "Removed legacy savestate v1 import $manager_file"
    fi
    if [[ -f "$manager_file" ]]; then
        echo "Unexpected savestate manager import would overwrite v2 baseline: $manager_file" >&2
        exit 1
    fi

    initializer="$import_dir/gml_Object_obj_initializer2_Create_0.gml"
    if [[ ! -f "$initializer" ]]; then
        echo "Missing initializer import: $initializer" >&2
        exit 1
    fi
    if ! rg -q "obj_savestate_manager\\.loading" "$initializer"; then
        perl -0pi -e 's/\A/if (obj_savestate_manager.loading)\n{\n    exit;\n}\n\n/' "$initializer"
    fi
    if ! rg -q "\\bmod_init\\(\\);" "$initializer"; then
        if [[ "$chapter" -ge 2 && "$chapter" -le 4 ]]; then
            perl -0pi -e 's/(textures_loaded = false;\n)/$1\nmod_init();\n/' "$initializer"
        else
            printf '\nmod_init();\n' >> "$initializer"
        fi
    fi
    if ! rg -q "obj_savestate_manager\\.loading" "$initializer" || ! rg -q "\\bmod_init\\(\\);" "$initializer"; then
        echo "Failed to preserve Keucher initializer hooks for chapter $chapter" >&2
        exit 1
    fi

    if [[ "$chapter" -eq 5 ]]; then
        town_event="$import_dir/gml_Object_obj_town_event_Create_0.gml"
        if [[ ! -f "$town_event" ]]; then
            echo "Missing Chapter 5 town event import: $town_event" >&2
            exit 1
        fi
        if ! rg -q "obj_savestate_manager\\.loading" "$town_event"; then
            perl -0pi -e 's/\A/if (obj_savestate_manager.loading)\n{\n    exit;\n}\n\n/' "$town_event"
        fi
        if ! rg -q "obj_savestate_manager\\.loading" "$town_event"; then
            echo "Failed to preserve Chapter 5 town event savestate guard" >&2
            exit 1
        fi
    fi

    output_file="$import_dir/${readable_step_code_name}.gml"
    tmp_file="${output_file}.tmp"

    dotnet run --project "$probe_project" -- decompile "$data_win" "$readable_step_code_name" > "$tmp_file"
    if ! rg -q "if \\(myinteract == 3\\)" "$tmp_file"; then
        echo "Expected obj_readable_room1 Step pattern not found for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi
    perl -0pi -e 's/\A/if (instance_exists(obj_savestate_manager) && obj_savestate_manager.loading)\n{\n    exit;\n}\nif (!variable_instance_exists(id, "myinteract"))\n{\n    myinteract = 0;\n}\n\n/s' "$tmp_file"
    if ! rg -q "instance_exists\\(obj_savestate_manager\\).*obj_savestate_manager\\.loading" "$tmp_file" ||
        ! rg -q "variable_instance_exists\\(id, \"myinteract\"\\)" "$tmp_file"; then
        echo "Readable Step hotfix insertion failed for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi

    mv "$tmp_file" "$output_file"
    echo "Wrote $output_file"
done
