#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <DeltaruneChinese workspace> [merged result dir]" >&2
    echo "Example: $0 work/DeltaruneChinese-keucher-v5.10.7/workspace" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project=${DATAWIN_PROBE_PROJECT:-"$root/tools/DataWinProbe"}
workspace=$1
result_dir=${2:-"$workspace/result"}

if [[ "$workspace" != /* ]]; then
    workspace="$(pwd)/$workspace"
fi
if [[ "$result_dir" != /* ]]; then
    result_dir="$(pwd)/$result_dir"
fi

for chapter in 1 2 3 4 5; do
    imports="$workspace/ch${chapter}/imports/code"
    data_win="$result_dir/ch${chapter}/data.win"
    if [[ ! -d "$imports" ]]; then
        echo "Missing imports directory: $imports" >&2
        exit 1
    fi
    if [[ ! -f "$data_win" ]]; then
        echo "Missing merged data.win: $data_win" >&2
        exit 1
    fi

    echo "Reinstrumenting chapter $chapter"
    dotnet run --project "$probe_project" -- \
        reinstrument-savestate-v2 "$data_win" "$imports" "$data_win"
done

echo "Reapplied Keucher savestate v2 instrumentation to merged CHS code"
