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

    for chapter in 1 2 3 4 5; do
        add_target_file "$target/chapter${chapter}_windows/data.win"
        add_target_file "$target/chapter${chapter}_windows/data_keucher.win"
    done
}

patch_code() {
    local data_win=$1
    local code_name=$2
    local gml_file="$tmp_dir/${code_name}_$(basename "$(dirname "$data_win")").gml"

    dotnet run --project "$probe_project" -- decompile "$data_win" "$code_name" > "$gml_file"

    case "$code_name" in
        gml_Object_obj_savestate_manager_Create_0)
            if ! rg -q "function decode_data_type\\(" "$gml_file" || ! rg -q "game_display_name" "$gml_file"; then
                echo "Expected Keucher savestate v2 Create event not found in $data_win" >&2
                exit 1
            fi

            if rg -q "array_contains_manual\\(sound_ids, string\\(value\\)\\)" "$gml_file"; then
                perl -0pi -e 's/\n\s*var sound_ids = variable_struct_get_names\(current_sounds\);\n/\n/' "$gml_file"
                perl -0pi -e 's/array_contains_manual\(sound_ids, string\(value\)\)/variable_struct_exists(current_sounds, string(value))/g' "$gml_file"
            fi

            if ! rg -q "function refresh_ds_max_ids\\(" "$gml_file"; then
                perl -0pi -e 's/(function encode_data_type\(arg0, arg1 = true\)\n\{)/function refresh_ds_max_ids()\n{\n    var i = ds_max_id.list;\n    while (i >= 0 && !ds_exists(i, 2))\n    {\n        i--;\n    }\n    ds_max_id.list = i;\n    i = ds_max_id.map;\n    while (i >= 0 && !ds_exists(i, 1))\n    {\n        i--;\n    }\n    ds_max_id.map = i;\n    i = ds_max_id.pqueue;\n    while (i >= 0 && !ds_exists(i, 6))\n    {\n        i--;\n    }\n    ds_max_id.pqueue = i;\n}\n\n$1/s' "$gml_file"
            fi

            if ! rg -q "base_imported_sprite_start" "$gml_file"; then
                perl -0pi -e 's/(highest_known_import_spr_id = imported_sprite_start - 1;)/base_imported_sprite_start = imported_sprite_start;\n$1/' "$gml_file"
            fi

            if rg -q "array_contains_manual\\(sound_ids, string\\(value\\)\\)" "$gml_file" ||
                ! rg -q "variable_struct_exists\\(current_sounds, string\\(value\\)\\)" "$gml_file" ||
                ! rg -q "function refresh_ds_max_ids\\(" "$gml_file" ||
                ! rg -q "base_imported_sprite_start = imported_sprite_start" "$gml_file" ||
                ! rg -U -q "function update_audio_info\\(\\)\\s*\\n\\{\\s*\\n\\s*var sound_ids = variable_struct_get_names\\(current_sounds\\);" "$gml_file"; then
                echo "Failed to patch savestate v2 Create event in $data_win" >&2
                exit 1
            fi
            ;;

        gml_Object_obj_savestate_manager_Alarm_0)
            perl -0pi -e 's/array_delete\(known_call_laters, c_later, 1\)/array_delete(known_call_laters, i, 1)/g' "$gml_file"
            if rg -q "array_delete\\(known_call_laters, c_later, 1\\)" "$gml_file" ||
                ! rg -q "array_delete\\(known_call_laters, i, 1\\)" "$gml_file"; then
                echo "Failed to patch call_later cleanup in $data_win" >&2
                exit 1
            fi
            ;;

        gml_Object_obj_savestate_manager_Step_1)
            if ! rg -U -q "refresh_ds_max_ids\\(\\);\\s*\\nvar ds_lists = \\[\\];" "$gml_file"; then
                perl -0pi -e 's/(\nvar ds_lists = \[\];)/\nrefresh_ds_max_ids();$1/' "$gml_file"
            fi
            perl -0pi -e 's/var pqueue_copy = ds_priority_create_logged\(\);/var pqueue_copy = ds_priority_create();/g' "$gml_file"
            if ! rg -U -q "refresh_ds_max_ids\\(\\);\\s*\\nvar ds_lists = \\[\\];" "$gml_file" ||
                rg -q "pqueue_copy = ds_priority_create_logged\\(\\)" "$gml_file" ||
                ! rg -q "pqueue_copy = ds_priority_create\\(\\)" "$gml_file"; then
                echo "Failed to patch savestate v2 save event in $data_win" >&2
                exit 1
            fi
            ;;

        gml_Object_obj_savestate_manager_Alarm_1)
            if ! rg -q "old_imported_sprite_id" "$gml_file"; then
                perl -0pi -e 's/(var sprite_folder = savestate_dir\(\) \+ "Sprites\/";)/$1\nfor (var old_imported_sprite_id = base_imported_sprite_start; old_imported_sprite_id <= highest_known_import_spr_id; old_imported_sprite_id++)\n{\n    if (sprite_exists(old_imported_sprite_id))\n    {\n        sprite_delete(old_imported_sprite_id);\n    }\n}\nimported_sprite_start = base_imported_sprite_start;\nhighest_known_import_spr_id = base_imported_sprite_start - 1;/' "$gml_file"
            fi
            if ! rg -q "highest_known_import_spr_id = imported_sprite_ids\\[0\\]" "$gml_file"; then
                perl -0pi -e 's/(imported_sprite_start = imported_sprite_ids\[0\];)/$1\n    highest_known_import_spr_id = imported_sprite_ids[0];/' "$gml_file"
            fi
            if ! rg -q "imported_sprite_ids\\[i\\] > highest_known_import_spr_id" "$gml_file"; then
                perl -0pi -e 's/(\n\s*if \(imported_sprite_ids\[i\] < imported_sprite_start\)\n\s*\{\n\s*imported_sprite_start = imported_sprite_ids\[i\];\n\s*\})/$1\n        if (imported_sprite_ids[i] > highest_known_import_spr_id)\n        {\n            highest_known_import_spr_id = imported_sprite_ids[i];\n        }/' "$gml_file"
            fi

            perl -0pi -e 's/ds_exists\(i, 2\)(\s*\)\s*\{\s*ds_list_destroy\(lists_to_destroy\[i\]\);)/ds_exists(lists_to_destroy[i], 2)$1/sg' "$gml_file"
            perl -0pi -e 's/ds_exists\(i, 1\)(\s*\)\s*\{\s*ds_map_destroy\(maps_to_destroy\[i\]\);)/ds_exists(maps_to_destroy[i], 1)$1/sg' "$gml_file"
            perl -0pi -e 's/ds_exists\(i, 6\)(\s*\)\s*\{\s*ds_priority_destroy\(pqueues_to_destroy\[i\]\);)/ds_exists(pqueues_to_destroy[i], 6)$1/sg' "$gml_file"

            if ! rg -U -q "set_globals\\(globals, true\\);\\s*\\nrefresh_ds_max_ids\\(\\);" "$gml_file"; then
                perl -0pi -e 's/set_globals\(globals, true\);/set_globals(globals, true);\nrefresh_ds_max_ids();/' "$gml_file"
            fi
            if ! rg -U -q "ds_priority_destroy\\(pqueues_to_destroy\\[i\\]\\);[\\s\\S]{0,160}refresh_ds_max_ids\\(\\);\\s*\\nfor \\(i = 0; i < array_length\\(audio_ids\\); i\\+\\+\\)" "$gml_file"; then
                perl -0pi -e 's/(\nfor \(i = 0; i < array_length\(audio_ids\); i\+\+\)\n\{\n\s*var audio_id = audio_ids\[i\];\n\s*audio_info = variable_struct_get\(audio, audio_id\);\n)(?![\s\S]*\nfor \(i = 0; i < array_length\(audio_ids\); i\+\+\)\n\{\n\s*var audio_id = audio_ids\[i\];\n\s*audio_info = variable_struct_get\(audio, audio_id\);\n)/\nrefresh_ds_max_ids();$1/' "$gml_file"
            fi

            if ! rg -q "sprite_delete\\(old_imported_sprite_id\\)" "$gml_file" ||
                ! rg -q "highest_known_import_spr_id = imported_sprite_ids\\[0\\]" "$gml_file" ||
                ! rg -q "imported_sprite_ids\\[i\\] > highest_known_import_spr_id" "$gml_file" ||
                ! rg -q "ds_exists\\(lists_to_destroy\\[i\\], 2\\)" "$gml_file" ||
                ! rg -q "ds_exists\\(maps_to_destroy\\[i\\], 1\\)" "$gml_file" ||
                ! rg -q "ds_exists\\(pqueues_to_destroy\\[i\\], 6\\)" "$gml_file" ||
                ! rg -U -q "set_globals\\(globals, true\\);\\s*\\nrefresh_ds_max_ids\\(\\);" "$gml_file" ||
                ! rg -U -q "ds_priority_destroy\\(pqueues_to_destroy\\[i\\]\\);[\\s\\S]{0,160}refresh_ds_max_ids\\(\\);\\s*\\nfor \\(i = 0; i < array_length\\(audio_ids\\); i\\+\\+\\)" "$gml_file"; then
                echo "Failed to patch savestate v2 load event in $data_win" >&2
                exit 1
            fi
            ;;

        *)
            echo "Unknown code name: $code_name" >&2
            exit 1
            ;;
    esac

    dotnet run --project "$probe_project" -- replace-code "$data_win" "$code_name" "$gml_file" "$data_win"
}

mapfile -t targets < <(
    for arg in "$@"; do
        collect_targets "$arg"
    done | awk '!seen[$0]++'
)

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "No chapter data.win files found in targets" >&2
    exit 1
fi

for data_win in "${targets[@]}"; do
    echo "Patching $data_win"
    patch_code "$data_win" gml_Object_obj_savestate_manager_Create_0
    patch_code "$data_win" gml_Object_obj_savestate_manager_Alarm_0
    patch_code "$data_win" gml_Object_obj_savestate_manager_Step_1
    patch_code "$data_win" gml_Object_obj_savestate_manager_Alarm_1
done

echo "Applied savestate v2 performance hotfix to ${#targets[@]} file(s)"
