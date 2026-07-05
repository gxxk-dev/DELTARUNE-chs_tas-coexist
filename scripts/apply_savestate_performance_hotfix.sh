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
            perl -0pi -e 's/(function encode_data_type\(arg0\)\n\{\n\s*var value = arg0;\n\s*var type = typeof\(value\);\n)\s*var sound_ids = variable_struct_get_names\(playing_sounds\);\n/$1/s' "$gml_file"
            perl -0pi -e 's/array_contains_manual\(sound_ids, value\)/variable_struct_exists(playing_sounds, value)/g' "$gml_file"
            if ! rg -q "function refresh_ds_max_ids\\(" "$gml_file"; then
                perl -0pi -e 's/(function encode_data_type\(arg0\)\n\{)/function refresh_ds_max_ids()\n{\n    var i = ds_max_id.list;\n    while (i >= 0 && !ds_exists(i, 2))\n    {\n        i--;\n    }\n    ds_max_id.list = i;\n    i = ds_max_id.map;\n    while (i >= 0 && !ds_exists(i, 1))\n    {\n        i--;\n    }\n    ds_max_id.map = i;\n    i = ds_max_id.pqueue;\n    while (i >= 0 && !ds_exists(i, 6))\n    {\n        i--;\n    }\n    ds_max_id.pqueue = i;\n}\n\n$1/s' "$gml_file"
            fi
            if ! rg -q "base_imported_sprite_start" "$gml_file"; then
                perl -0pi -e 's/(highest_known_import_spr_id = imported_sprite_start - 1;)/base_imported_sprite_start = imported_sprite_start;\n$1/s' "$gml_file"
            fi
            perl -0pi -e 's/function set_globals\(arg0, arg1 = false, arg2 = true\)/function set_globals(arg0, arg1 = false, arg2 = true, arg3 = true)/g' "$gml_file"
            if ! rg -q "if \\(!arg3\\)" "$gml_file"; then
                perl -0pi -e 's/(\n\s*var ds = load_game_info\.ds;)/\n    if (!arg3)\n    {\n        exit;\n    }\n$1/s' "$gml_file"
            fi
            perl -0pi -e 's/ds_exists\(i, 2\)(\s*\)\s*\{\s*ds_list_destroy\(lists_to_destroy\[i\]\);)/ds_exists(lists_to_destroy[i], 2)$1/sg' "$gml_file"
            perl -0pi -e 's/ds_exists\(i, 1\)(\s*\)\s*\{\s*ds_map_destroy\(maps_to_destroy\[i\]\);)/ds_exists(maps_to_destroy[i], 1)$1/sg' "$gml_file"
            perl -0pi -e 's/ds_exists\(i, 6\)(\s*\)\s*\{\s*ds_priority_destroy\(pqueues_to_destroy\[i\]\);)/ds_exists(pqueues_to_destroy[i], 6)$1/sg' "$gml_file"
            if ! rg -q "refresh_ds_max_ids\\(\\);\\s*if \\(!pqueues_logged\\)" "$gml_file"; then
                perl -0pi -e 's/(\n\s*if \(!pqueues_logged\)\n\s*\{)/\n    refresh_ds_max_ids();$1/s' "$gml_file"
            fi
            if ! rg -U -q "refresh_ds_max_ids\\(\\);\\s*\\n\\}\\s*\\n\\s*function update_audio_info" "$gml_file"; then
                perl -0pi -e 's/\n\}\n\nfunction update_audio_info\(\)\n\{/\n    refresh_ds_max_ids();\n}\n\nfunction update_audio_info()\n{/s' "$gml_file"
            fi
            if ! rg -U -q "function update_audio_info\\(\\)\\s*\\n\\{\\s*\\n\\s*var sound_ids = variable_struct_get_names\\(playing_sounds\\);" "$gml_file"; then
                perl -0pi -e 's/(function update_audio_info\(\)\n\{\n)/$1    var sound_ids = variable_struct_get_names(playing_sounds);\n/s' "$gml_file"
            fi
            perl -0pi -e 's/set_globals\(load_game_info\.globals, false, false\);/set_globals(load_game_info.globals, false, false, false);/g' "$gml_file"
            if rg -q "array_contains_manual\\(sound_ids, value\\)" "$gml_file" || ! rg -q "variable_struct_exists\\(playing_sounds, value\\)" "$gml_file"; then
                echo "Failed to patch audio lookup in $data_win" >&2
                exit 1
            fi
            if ! rg -q "function refresh_ds_max_ids\\(" "$gml_file" ||
                ! rg -q "function set_globals\\(arg0, arg1 = false, arg2 = true, arg3 = true\\)" "$gml_file" ||
                ! rg -q "ds_exists\\(lists_to_destroy\\[i\\], 2\\)" "$gml_file" ||
                ! rg -q "ds_exists\\(maps_to_destroy\\[i\\], 1\\)" "$gml_file" ||
                ! rg -q "ds_exists\\(pqueues_to_destroy\\[i\\], 6\\)" "$gml_file" ||
                ! rg -q "var sound_ids = variable_struct_get_names\\(playing_sounds\\);" "$gml_file"; then
                echo "Failed to patch DS rebuild cleanup in $data_win" >&2
                exit 1
            fi
            ;;
        gml_Object_obj_savestate_manager_Step_1)
            perl -0pi -e 's/array_delete\(known_call_laters, c_later, 1\)/array_delete(known_call_laters, i, 1)/g' "$gml_file"
            if rg -q "array_delete\\(known_call_laters, c_later, 1\\)" "$gml_file" || ! rg -q "array_delete\\(known_call_laters, i, 1\\)" "$gml_file"; then
                echo "Failed to patch call_later cleanup in $data_win" >&2
                exit 1
            fi
            ;;
        gml_Object_obj_savestate_manager_Alarm_1)
            if ! rg -q "refresh_ds_max_ids\\(\\);" "$gml_file"; then
                perl -0pi -e 's/(\nvar ds_lists = \[\];)/\nrefresh_ds_max_ids();$1/s' "$gml_file"
            fi
            perl -0pi -e 's/var pqueue_copy = ds_priority_create_logged\(\);/var pqueue_copy = ds_priority_create();/g' "$gml_file"
            if rg -q "pqueue_copy = ds_priority_create_logged\\(\\)" "$gml_file" || ! rg -q "pqueue_copy = ds_priority_create\\(\\)" "$gml_file" || ! rg -q "refresh_ds_max_ids\\(\\);" "$gml_file"; then
                echo "Failed to patch pqueue copy in $data_win" >&2
                exit 1
            fi
            ;;
        gml_Object_obj_savestate_manager_Alarm_0)
            if ! rg -q "old_imported_sprite_id" "$gml_file"; then
                perl -0pi -e 's/(var sprite_folder = savestate_dir\(\) \+ "Sprites\/";)/$1\nfor (var old_imported_sprite_id = base_imported_sprite_start; old_imported_sprite_id <= highest_known_import_spr_id; old_imported_sprite_id++)\n{\n    if (sprite_exists(old_imported_sprite_id))\n    {\n        sprite_delete(old_imported_sprite_id);\n    }\n}\nimported_sprite_start = base_imported_sprite_start;\nhighest_known_import_spr_id = base_imported_sprite_start - 1;/s' "$gml_file"
            fi
            if ! rg -q "highest_known_import_spr_id = imported_sprite_ids\\[0\\]" "$gml_file"; then
                perl -0pi -e 's/(imported_sprite_start = imported_sprite_ids\[0\];)/$1\n    highest_known_import_spr_id = imported_sprite_ids[0];/s' "$gml_file"
            fi
            if ! rg -q "imported_sprite_ids\\[i\\] > highest_known_import_spr_id" "$gml_file"; then
                perl -0pi -e 's/(\n\s*if \(imported_sprite_ids\[i\] < imported_sprite_start\)\n\s*\{\n\s*imported_sprite_start = imported_sprite_ids\[i\];\n\s*\})/$1\n        if (imported_sprite_ids[i] > highest_known_import_spr_id)\n        {\n            highest_known_import_spr_id = imported_sprite_ids[i];\n        }/s' "$gml_file"
            fi
            perl -0pi -e 's/set_globals\(globals, true\);/set_globals(globals, true, true, false);/g' "$gml_file"
            if rg -q "set_globals\\(globals, true\\);" "$gml_file" ||
                ! rg -q "set_globals\\(globals, true, true, false\\);" "$gml_file" ||
                ! rg -q "sprite_delete\\(old_imported_sprite_id\\)" "$gml_file" ||
                ! rg -q "highest_known_import_spr_id = imported_sprite_ids\\[0\\]" "$gml_file"; then
                echo "Failed to patch final globals restore in $data_win" >&2
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
    patch_code "$data_win" gml_Object_obj_savestate_manager_Step_1
    patch_code "$data_win" gml_Object_obj_savestate_manager_Alarm_1
    patch_code "$data_win" gml_Object_obj_savestate_manager_Alarm_0
done

echo "Applied savestate performance hotfix to ${#targets[@]} file(s)"
