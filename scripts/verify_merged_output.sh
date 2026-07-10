#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project=${DATAWIN_PROBE_PROJECT:-"$root/tools/DataWinProbe"}
output=${1:-"$root/output"}
conflicts=${CODE_CONFLICT_OUT:-"$root/verify/code_conflicts_v5.10.7"}
tmp_dir="$(mktemp -d)"

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

if [[ "$output" != /* ]]; then
    output="$(pwd)/$output"
fi

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Missing required output: $1" >&2
        exit 1
    fi
}

require_pattern() {
    local pattern=$1
    local file=$2
    local message=$3
    if ! rg -q "$pattern" "$file"; then
        echo "$message" >&2
        exit 1
    fi
}

decompile() {
    local data_win=$1
    local code_name=$2
    local destination=$3
    dotnet run --project "$probe_project" -- decompile "$data_win" "$code_name" > "$destination"
}

require_file "$output/data.win"
for chapter in 1 2 3 4 5; do
    data_win="$output/chapter${chapter}_windows/data.win"
    require_file "$data_win"
    for lang in lang_en.json lang_en_names.json lang_en_names_recruitable.json; do
        require_file "$output/chapter${chapter}_windows/lang/$lang"
    done

    create="$tmp_dir/ch${chapter}-savestate-create.gml"
    decompile "$data_win" gml_Object_obj_savestate_manager_Create_0 "$create"
    require_pattern 'function decode_data_type\(' "$create" "Chapter $chapter does not contain Keucher savestate v2"
    require_pattern 'game_display_name' "$create" "Chapter $chapter uses the legacy savestate directory layout"
    require_pattern 'asset_get_index\(arg0\.const_func\)' "$create" "Chapter $chapter is missing constructor-name restoration"
    require_pattern 'function refresh_ds_max_ids\(' "$create" "Chapter $chapter is missing the savestate v2 DS performance fix"
    require_pattern 'variable_struct_exists\(current_sounds, string\(value\)\)' "$create" "Chapter $chapter is missing the savestate audio lookup fix"

    alarm0="$tmp_dir/ch${chapter}-savestate-alarm0.gml"
    decompile "$data_win" gml_Object_obj_savestate_manager_Alarm_0 "$alarm0"
    require_pattern 'array_delete\(known_call_laters, i, 1\)' "$alarm0" "Chapter $chapter is missing call_later cleanup"

    step="$tmp_dir/ch${chapter}-savestate-step.gml"
    decompile "$data_win" gml_Object_obj_savestate_manager_Step_1 "$step"
    require_pattern 'pqueue_copy = ds_priority_create\(\)' "$step" "Chapter $chapter still logs the temporary priority queue"

    alarm1="$tmp_dir/ch${chapter}-savestate-alarm1.gml"
    decompile "$data_win" gml_Object_obj_savestate_manager_Alarm_1 "$alarm1"
    require_pattern 'sprite_delete\(old_imported_sprite_id\)' "$alarm1" "Chapter $chapter is missing imported-sprite cleanup"
    require_pattern 'ds_exists\(lists_to_destroy\[i\], 2\)' "$alarm1" "Chapter $chapter has incorrect DS list cleanup"
    require_pattern 'ds_exists\(maps_to_destroy\[i\], 1\)' "$alarm1" "Chapter $chapter has incorrect DS map cleanup"
    require_pattern 'ds_exists\(pqueues_to_destroy\[i\], 6\)' "$alarm1" "Chapter $chapter has incorrect DS priority cleanup"

    readable="$tmp_dir/ch${chapter}-readable-step.gml"
    decompile "$data_win" gml_Object_obj_readable_room1_Step_0 "$readable"
    require_pattern 'instance_exists\([^)]*\).*obj_savestate_manager\.loading' "$readable" "Chapter $chapter readable-room loading guard is missing"
    require_pattern 'variable_instance_exists\(id, "myinteract"\)' "$readable" "Chapter $chapter readable-room fallback is missing"
done

flowery="$tmp_dir/ch5-flowery-step.gml"
decompile "$output/chapter5_windows/data.win" gml_Object_obj_flowery_enemy_Step_0 "$flowery"
require_pattern 'boss_practice_patterns\[global\.bossTurn\]' "$flowery" "Chapter 5 Flowery boss practice is missing"
require_pattern 'reset_graze_condition\(\)' "$flowery" "Chapter 5 Flowery graze reset fix is missing"

initializer="$tmp_dir/ch5-initializer.gml"
decompile "$output/chapter5_windows/data.win" gml_Object_obj_initializer2_Create_0 "$initializer"
if [[ "$(rg -c 'global\.versionno = "v0\.0\.247"' "$initializer")" -ne 3 ]]; then
    echo "Chapter 5 does not identify DELTARUNE v0.0.247" >&2
    exit 1
fi

credits="$tmp_dir/ch5-credits.gml"
decompile "$output/chapter5_windows/data.win" gml_GlobalScript_scr_credit "$credits"
require_pattern 'stringsetloc\("-Platforming VFX-"' "$credits" "Chapter 5 v0.0.247 credits are missing"
require_pattern 'stringsetloc\("-Musical Assistance-"' "$credits" "Chapter 5 v0.0.247 musical credit is missing"

terracota="$tmp_dir/ch5-terracota.gml"
decompile "$output/chapter5_windows/data.win" gml_Object_obj_terracota_enemy_Step_0 "$terracota"
for timer in 275 245 365; do
    require_pattern "scr_turntimer\\($timer\\)" "$terracota" "Chapter 5 Terracota timer $timer is missing"
done

mod_init="$tmp_dir/ch5-mod-init.gml"
decompile "$output/chapter5_windows/data.win" gml_GlobalScript_mod_init "$mod_init"
manager_id="$(dotnet run --project "$probe_project" -- object-index "$output/chapter5_windows/data.win" obj_savestate_manager)"
require_pattern "create_array\\([^)]*([^0-9]|^)${manager_id}([^0-9]|$)" "$mod_init" "Chapter 5 mod_init does not keep the savestate manager alive"

for code_name in gml_Object_obj_pause_emulator_Create_0 gml_Object_obj_time_Create_0 gml_Object_obj_time_Step_1; do
    guard="$tmp_dir/ch5-${code_name}.gml"
    decompile "$output/chapter5_windows/data.win" "$code_name" "$guard"
    require_pattern 'instance_exists\([^)]*\).*obj_savestate_manager\.loading' "$guard" "Chapter 5 loading guard is unsafe in $code_name"
done

gif_draw="$tmp_dir/ch5-time-draw77.gml"
decompile "$output/chapter5_windows/data.win" gml_Object_obj_time_Draw_77 "$gif_draw"
if rg -q 'gif_open|gif_add_surface|gif_save' "$gif_draw"; then
    echo "Chapter 5 still contains the vanilla GIF recorder" >&2
    exit 1
fi

if [[ -d "$conflicts" ]] && rg -q '^merged_lost_keucher' "$conflicts"/*.tsv; then
    echo "Code conflict report contains merged_lost_keucher entries" >&2
    exit 1
fi

echo "Merged output verification passed"
