#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_project="$root/tools/DataWinProbe/DataWinProbe.csproj"
game="${DELTARUNE_GAME_DIR:?set DELTARUNE_GAME_DIR to the DELTARUNE install directory}"
keucher="${KEUCHER_BUILD_DIR:-$root/build/keucher}"
merged="${MERGED_RESULT_DIR:-$root/work/DeltaruneChinese/workspace/result}"
out="${CODE_CONFLICT_OUT:-$root/verify/code_conflicts}"

rm -rf "$out"
mkdir -p "$out"

decompile() {
  local datawin="$1"
  local code="$2"
  local dest="$3"
  DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    dotnet run --project "$probe_project" -- decompile "$datawin" "$code" > "$dest"
}

check_one() {
  local label="$1"
  local vanilla_data="$2"
  local keucher_data="$3"
  local merged_data="$4"
  local list="$root/verify/code_lists/$label.txt"
  local report="$out/$label.tsv"
  mkdir -p "$out/$label"
  : > "$report"

  while IFS= read -r code; do
    [ -n "$code" ] || continue
    local safe="${code//\//_}"
    local v="$out/$label/${safe}.vanilla.gml"
    local k="$out/$label/${safe}.keucher.gml"
    local m="$out/$label/${safe}.merged.gml"
    decompile "$vanilla_data" "$code" "$v"
    decompile "$keucher_data" "$code" "$k"
    decompile "$merged_data" "$code" "$m"

    local vh kh mh
    vh="$(sha256sum "$v" | awk '{print $1}')"
    kh="$(sha256sum "$k" | awk '{print $1}')"
    mh="$(sha256sum "$m" | awk '{print $1}')"
    if [ "$vh" != "$kh" ]; then
      local status="keucher_changed"
      if [ "$kh" = "$mh" ]; then
        status="merged_matches_keucher"
      elif [ "$vh" = "$mh" ]; then
        status="merged_lost_keucher"
      else
        status="merged_differs_from_both"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$code" "$vh" "$kh" "$mh" >> "$report"
    fi
  done < "$list"
}

check_one main "$game/data.win" "$keucher/data.win" "$merged/main/data.win"
for c in 1 2 3 4 5; do
  check_one "ch$c" \
    "$game/chapter${c}_windows/data.win" \
    "$keucher/chapter${c}_windows/data.win" \
    "$merged/ch$c/data.win"
done

cat "$out"/*.tsv
