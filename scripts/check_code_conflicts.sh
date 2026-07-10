#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project="$root/tools/DataWinProbe/DataWinProbe.csproj"
game="${DELTARUNE_GAME_DIR:?set DELTARUNE_GAME_DIR to the DELTARUNE install directory}"
keucher="${KEUCHER_BUILD_DIR:-$root/build/keucher-v5.10.7}"
merged="${MERGED_RESULT_DIR:-$root/work/DeltaruneChinese-keucher-v5.10.7/workspace/result}"
out="${CODE_CONFLICT_OUT:-$root/verify/code_conflicts_v5.10.7}"
code_lists="${CODE_LIST_DIR:-$root/verify/code_lists_v5.10.7}"

if [[ -f "$merged/main/data.win" ]]; then
  merged_main="$merged/main/data.win"
  merged_chapter() { printf '%s/ch%s/data.win\n' "$merged" "$1"; }
elif [[ -f "$merged/data.win" ]]; then
  merged_main="$merged/data.win"
  merged_chapter() { printf '%s/chapter%s_windows/data.win\n' "$merged" "$1"; }
else
  echo "unrecognized merged result layout: $merged" >&2
  exit 2
fi

rm -rf "$out"
mkdir -p "$out"

check_one() {
  local label="$1"
  local vanilla_data="$2"
  local keucher_data="$3"
  local merged_data="$4"
  local list="$code_lists/$label.txt"
  local report="$out/$label.tsv"
  DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    dotnet run --project "$probe_project" -- \
      compare-code "$vanilla_data" "$keucher_data" "$merged_data" "$list" > "$report"
}

check_one main "$game/data.win" "$keucher/data.win" "$merged_main"
for c in 1 2 3 4 5; do
  check_one "ch$c" \
    "$game/chapter${c}_windows/data.win" \
    "$keucher/chapter${c}_windows/data.win" \
    "$(merged_chapter "$c")"
done

cat "$out"/*.tsv
