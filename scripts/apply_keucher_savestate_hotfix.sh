#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <DeltaruneChinese workspace> <Keucher baseline dir>" >&2
    echo "Example: $0 work/DeltaruneChinese-260704/workspace build/keucher" >&2
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
    output_file="$import_dir/${savestate_code_name}.gml"
    tmp_file="${output_file}.tmp"

    if [[ ! -f "$data_win" ]]; then
        echo "Missing Keucher baseline: $data_win" >&2
        exit 1
    fi
    if [[ ! -d "$import_dir" ]]; then
        echo "Missing import dir: $import_dir" >&2
        exit 1
    fi

    dotnet run --project "$probe_project" -- decompile "$data_win" "$savestate_code_name" > "$tmp_file"
    if ! rg -q "new arg0\\.const_func\\(\\)" "$tmp_file"; then
        echo "Expected constructor restore pattern not found for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi

    perl -0pi -e 's/if \(type == "constructor"\)\s*\{\s*struct = new arg0\.const_func\(\);\s*\}/if (type == "constructor")\n            {\n                try\n                {\n                    var const_func = arg0.const_func;\n                    if (typeof(const_func) == "number")\n                    {\n                        const_func = method(undefined, const_func);\n                    }\n                    struct = new const_func();\n                }\n                catch (_exception)\n                {\n                    struct = {};\n                }\n            }/s' "$tmp_file"

    if ! rg -q "method\\(undefined, const_func\\)" "$tmp_file" || rg -q "new arg0\\.const_func\\(\\)" "$tmp_file"; then
        echo "Hotfix replacement failed for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi

    mv "$tmp_file" "$output_file"
    echo "Wrote $output_file"

    output_file="$import_dir/${readable_step_code_name}.gml"
    tmp_file="${output_file}.tmp"

    dotnet run --project "$probe_project" -- decompile "$data_win" "$readable_step_code_name" > "$tmp_file"
    if ! rg -q "if \\(myinteract == 3\\)" "$tmp_file"; then
        echo "Expected obj_readable_room1 Step pattern not found for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi
    if ! rg -q "obj_savestate_manager\\.loading" "$tmp_file"; then
        perl -0pi -e 's/\A/if (obj_savestate_manager.loading)\n{\n    exit;\n}\nif (!variable_instance_exists(id, "myinteract"))\n{\n    myinteract = 0;\n}\n\n/s' "$tmp_file"
    fi
    if ! rg -q "variable_instance_exists\\(id, \"myinteract\"\\)" "$tmp_file"; then
        echo "Readable Step hotfix insertion failed for chapter $chapter" >&2
        rm -f "$tmp_file"
        exit 1
    fi

    mv "$tmp_file" "$output_file"
    echo "Wrote $output_file"
done
