#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <DeltaruneChinese workspace>" >&2
    echo "Example: $0 work/DeltaruneChinese-keucher-v5.10.7/workspace" >&2
    exit 2
fi

workspace=$1
if [[ "$workspace" != /* ]]; then
    workspace="$(pwd)/$workspace"
fi
code_dir="$workspace/ch5/imports/code"
if [[ ! -d "$code_dir" ]]; then
    echo "Missing Chapter 5 imports directory: $code_dir" >&2
    exit 1
fi

credits="$code_dir/gml_GlobalScript_scr_credit.gml"
initializer="$code_dir/gml_Object_obj_initializer2_Create_0.gml"
terracota="$code_dir/gml_Object_obj_terracota_enemy_Step_0.gml"
cliff_scene="$code_dir/gml_Object_obj_ch5_DWCR01_Step_0.gml"

for file in "$credits" "$initializer" "$terracota" "$cliff_scene"; do
    if [[ ! -f "$file" ]]; then
        echo "Missing Chapter 5 compatibility input: $file" >&2
        exit 1
    fi
done

perl -0pi -e 's/new scr_credit\(\[stringsetloc\("-Area & Fashion Concept Art-", "scr_credit_slash_scr_credit_gml_58_0"\)\], \[stringset\("Gigi DG"\)\]\)/new scr_credit([stringsetloc("-Concept Art-", "scr_credit_slash_scr_credit_gml_58_0")], [stringsetloc("Gigi DG (Susie outfits)", "scr_credit_slash_scr_credit_gml_62_0"), stringsetloc("Matt Cummings (Festival)", "scr_credit_slash_scr_credit_gml_63_0")])/g' "$credits"
perl -0pi -e 's/(new scr_credit\(\[stringsetloc\("-Guest Bullet Program-", "scr_credit_slash_scr_credit_gml_74_0"\)\], \[stringset\("Eebrozgi"\)\]\))\];/$1, new scr_credit([stringsetloc("-Platforming VFX-", "scr_credit_slash_scr_credit_gml_82_0")], [stringset("Zu Ehtisham")])];/g' "$credits"
perl -0pi -e 's/\Qstringset("Itoki Hana")]), new scr_credit([stringsetloc("-Anime Cutscene SFX-",\E/stringset("Itoki Hana")]), new scr_credit([stringsetloc("-Musical Assistance-", "scr_credit_slash_scr_credit_gml_273_0")], [stringset("Marcy Nabors")]), new scr_credit([stringsetloc("-Anime Cutscene SFX-",/g' "$credits"

perl -0pi -e 's/v0\.0\.244/v0.0.247/g' "$initializer"
perl -0pi -e 's/scr_turntimer\(270\)/scr_turntimer(275)/g; s/scr_turntimer\(240\)/scr_turntimer(245)/g; s/scr_turntimer\(360\)/scr_turntimer(365)/g' "$terracota"

if ! rg -q 'stringsetloc\("-Concept Art-"' "$credits" ||
    ! rg -q 'stringsetloc\("-Platforming VFX-"' "$credits" ||
    ! rg -q 'stringsetloc\("-Musical Assistance-"' "$credits" ||
    rg -q 'Area & Fashion Concept Art' "$credits"; then
    echo "Failed to merge the v0.0.247 Chapter 5 credits update" >&2
    exit 1
fi
if [[ "$(rg -c 'global\.versionno = "v0\.0\.247"' "$initializer")" -ne 3 ]]; then
    echo "Failed to merge the v0.0.247 Chapter 5 version number" >&2
    exit 1
fi
for timer in 275 245 365; do
    if ! rg -q "scr_turntimer\\($timer\\)" "$terracota"; then
        echo "Failed to merge Chapter 5 Terracota timer $timer" >&2
        exit 1
    fi
done
if [[ "$(rg -c 'interjection = -1;' "$cliff_scene")" -lt 2 ]]; then
    echo "DeltaruneChinese input is missing the v0.0.247 cliff-scene interjection fix" >&2
    exit 1
fi

echo "Merged DELTARUNE v0.0.247 Chapter 5 fixes into CHS imports"
