#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
version_file="$root/versions/pc-v0.0.247-f3437be-260710.json"
ralsei_version_file="$root/versions/ralsei-portraits-samuton-v1.json"

declare -a data_rels=()
declare -a vanilla_hashes=()
declare -a merged_hashes=()
declare -a ralsei_hashes=()
declare -a ralsei_bytes=()
declare -a selected_hashes=()
declare -a selected_bytes=()
declare -a external_rels=()
declare -a external_bytes=()
declare -a external_hashes=()
declare -a expected_backup_rels=()
declare -a expected_backup_hashes=()
declare -a expected_backup_ralsei_hashes=()
declare -a expected_output_rels=()
ralsei_variant_json="null"
ralsei_expected_outputs_json=""
build_id=""
game_version=""
version_json=""

declare -a target_rels=()
declare -a target_sources=()
declare -a target_hashes=()
declare -A target_seen=()
declare -a created_dirs=()
declare -A created_dir_seen=()
declare -a apply_states=()
declare -a apply_original_hashes=()
declare -a apply_written_indices=()
declare -a apply_created_dirs=()

operation=""
writes_started=0
stage_dir=""
lock_dir=""
lock_owned=0
backup_dir=""
latest_tmp=""
preserve_stage=0

usage() {
  cat >&2 <<'EOF'
Usage:
  ./install_output.sh apply --game-dir DIR [--output-dir DIR]
  ./install_output.sh restore --game-dir DIR [--backup DIR]

For compatibility, ./install_output.sh DIR is the same as apply --game-dir DIR.
DELTARUNE_GAME_DIR may be used instead of --game-dir.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

hash_file() {
  local result
  result="$(sha256sum -- "$1")"
  printf '%s\n' "${result%% *}"
}

relative_parent() {
  if [[ "$1" == */* ]]; then
    printf '%s\n' "${1%/*}"
  else
    printf '.\n'
  fi
}

is_sha256() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

is_safe_relative_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != "." && "$path" != ".." &&
    "$path" != ../* && "$path" != */../* && "$path" != */.. &&
    "$path" != ./* && "$path" != */./* && "$path" != */. &&
    "$path" != *//* && "$path" != *$'\n'* && "$path" != *$'\r'* &&
    "$path" != *$'\t'* ]]
}

paths_overlap() {
  local first="$1"
  local second="$2"
  if [ "$first" = "/" ] || [ "$second" = "/" ]; then
    return 0
  fi
  [[ "$first" == "$second" || "$first" == "$second/"* || "$second" == "$first/"* ]]
}

destination_parent_is_safe() {
  local game="$1"
  local rel="$2"
  local parent component accumulated=""
  local -a components=()

  parent="${rel%/*}"
  [ "$parent" != "$rel" ] || return 0
  IFS='/' read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    if [ -n "$accumulated" ]; then
      accumulated+="/$component"
    else
      accumulated="$component"
    fi
    [ -d "$game/$accumulated" ] && [ ! -L "$game/$accumulated" ] || return 1
  done
}

destination_parent_is_safe_or_missing() {
  local game="$1"
  local rel="$2"
  local parent component accumulated=""
  local -a components=()

  parent="${rel%/*}"
  [ "$parent" != "$rel" ] || return 0
  IFS='/' read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    if [ -n "$accumulated" ]; then
      accumulated+="/$component"
    else
      accumulated="$component"
    fi
    if [ -L "$game/$accumulated" ]; then
      return 1
    elif [ -e "$game/$accumulated" ]; then
      [ -d "$game/$accumulated" ] || return 1
    else
      return 0
    fi
  done
}

source_path_is_safe() {
  local source_root="$1"
  local rel="$2"
  local parent component accumulated=""
  local -a components=()

  is_safe_relative_path "$rel" || return 1
  [ -d "$source_root" ] && [ ! -L "$source_root" ] || return 1
  parent="${rel%/*}"
  if [ "$parent" != "$rel" ]; then
    IFS='/' read -r -a components <<<"$parent"
    for component in "${components[@]}"; do
      if [ -n "$accumulated" ]; then
        accumulated+="/$component"
      else
        accumulated="$component"
      fi
      [ -d "$source_root/$accumulated" ] && [ ! -L "$source_root/$accumulated" ] || return 1
    done
  fi
  [ -f "$source_root/$rel" ] && [ ! -L "$source_root/$rel" ]
}

canonical_dir() {
  local path="$1"
  [ -d "$path" ] || die "directory does not exist: $path"
  (cd "$path" && pwd -P)
}

require_commands() {
  local command
  for command in sha256sum cp find git ln mv mkdir mktemp date stat rm rmdir; do
    command -v "$command" >/dev/null 2>&1 || die "required command not found: $command"
  done
}

load_ralsei_version_manifest() {
  local ralsei_json expected_inputs base_outputs records_text record

  [ -f "$ralsei_version_file" ] && [ ! -L "$ralsei_version_file" ] ||
    die "missing Ralsei portrait manifest: $ralsei_version_file"
  ralsei_json="$(<"$ralsei_version_file")"
  expected_inputs="$(jq -ce '[.deltarune.files[1:][] | {
      chapter: .id, rel, input_sha256: .output_sha256
    }]' <<<"$version_json")" || die "could not read Ralsei input bindings"
  jq -e --argjson expected_inputs "$expected_inputs" '
    def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
    def positive_integer: type == "number" and isfinite and floor == . and . > 0;
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    exact([
      "schema", "id", "archive", "importer", "mapping_contract", "outputs", "files"
    ]) and
    .schema == 2 and .id == "ralsei-portraits-samuton-v1" and
    (.archive | exact(["filename", "format", "bytes", "sha256"]) and
      .format == "7z" and (.bytes | positive_integer) and (.sha256 | digest)) and
    (.importer | type == "object") and
    (.mapping_contract | type == "object") and (.files | type == "array") and
    (.outputs | type == "array" and length == 5) and
    all(.outputs[];
      exact(["chapter", "rel", "input_bytes", "input_sha256", "bytes", "sha256"]) and
      (.chapter | type == "string" and test("^ch[1-5]$")) and
      (.rel | type == "string" and test("^chapter[1-5]_windows/data[.]win$")) and
      (.input_bytes | positive_integer) and (.input_sha256 | digest) and
      (.bytes | positive_integer) and (.sha256 | digest)) and
    ([.outputs[] | {chapter, rel, input_sha256}] == $expected_inputs)
  ' <<<"$ralsei_json" >/dev/null || die "invalid Ralsei portrait manifest"

  ralsei_variant_json="$(jq -cn \
    --argjson asset "$(jq -ce '{id, bytes: .archive.bytes, sha256: .archive.sha256}' \
      <<<"$ralsei_json")" \
    '{kind: "ralsei_portraits", asset: $asset}')" ||
    die "could not create the Ralsei variant identity"
  base_outputs="$(jq -ce '[.deltarune.files[] | {rel, sha256: .output_sha256}]' \
    <<<"$version_json")" || die "could not read base output bindings"
  ralsei_expected_outputs_json="$(jq -cn \
    --argjson base "$base_outputs" \
    --argjson replacements "$(jq -ce '[.outputs[] | {rel, bytes, sha256}]' \
      <<<"$ralsei_json")" '
    $base | map(. as $output |
      ($replacements | map(select(.rel == $output.rel)) | first) as $replacement |
      if $replacement == null then $output
      else {rel: $output.rel, sha256: $replacement.sha256}
      end)
  ')" || die "could not create the Ralsei output bindings"

  ralsei_hashes=("${merged_hashes[0]}")
  ralsei_bytes=("-")
  records_text="$(jq -er '.outputs[] | [(.bytes | tostring), .sha256] | @tsv' \
    <<<"$ralsei_json")" || die "could not read Ralsei output records"
  while IFS=$'\t' read -r bytes hash extra; do
    [ -z "${extra:-}" ] || die "invalid Ralsei output record"
    ralsei_bytes+=("$bytes")
    ralsei_hashes+=("$hash")
  done <<<"$records_text"
  [ "${#ralsei_hashes[@]}" -eq 6 ] && [ "${#ralsei_bytes[@]}" -eq 6 ] ||
    die "Ralsei portrait manifest must define five chapter outputs"
}

load_version_manifest() {
  local -a records=()
  local records_text record id rel bytes vanilla_hash merged_hash

  [ -f "$version_file" ] && [ ! -L "$version_file" ] ||
    die "missing version manifest: $version_file"
  "$root/scripts/check_version_lock.sh" "$version_file" >/dev/null ||
    die "version manifest failed strict validation: $version_file"
  version_json="$(<"$version_file")"
  jq -e '
    .schema == 2 and
    (.id | type == "string" and length > 0) and
    (.deltarune.version | type == "string" and length > 0) and
    ([.deltarune.files[].id] == ["main", "ch1", "ch2", "ch3", "ch4", "ch5"]) and
    ([.deltarune.files[].rel] == [
      "data.win", "chapter1_windows/data.win", "chapter2_windows/data.win",
      "chapter3_windows/data.win", "chapter4_windows/data.win",
      "chapter5_windows/data.win"
    ]) and
    all(.deltarune.files[];
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.output_sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.output_extras | type == "array") and
    all(.output_extras[];
      (.rel | type == "string" and length > 0) and
      (.bytes | type == "number" and isfinite and floor == . and . > 0) and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) and
    (.audio.outputs | type == "array" and length > 0) and
    ([.audio.outputs[]] | length == (unique | length)) and
    all(.audio.outputs[]; type == "string" and length > 0) and
    (.audio.codec | type == "string" and length > 0) and
    (.audio.sample_rate | type == "number" and isfinite and floor == . and . > 0) and
    (.audio.channels | type == "number" and isfinite and floor == . and . > 0) and
    (.audio.duration | type == "number" and isfinite and . > 0) and
    (.audio.source_bytes | type == "number" and isfinite and floor == . and . > 0) and
    (.audio.source_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    .audio.fingerprint_algorithm == "chromaprint-v1" and
    (.audio.fingerprint_seconds | type == "number" and isfinite and floor == . and . > 0) and
    (.audio.fingerprint_min_similarity | type == "number" and
      . >= 0.9 and . <= 1) and
    (.audio.fingerprint_raw | type == "string" and
      test("^[0-9]+(,[0-9]+)+$")) and
    (.upstreams | type == "object") and
    (.adapters | type == "object") and
    (.tools.undertale_mod_cli | type == "object")
  ' <<<"$version_json" >/dev/null || die "invalid version manifest: $version_file"

  build_id="$(jq -er '.id' <<<"$version_json")" || die "could not read build id"
  game_version="$(jq -er '.deltarune.version' <<<"$version_json")" ||
    die "could not read game version"
  records_text="$(jq -er \
    '.deltarune.files[] | [.id, .rel, .sha256, .output_sha256] | @tsv' \
    <<<"$version_json")" || die "could not read game file records"
  mapfile -t records <<<"$records_text"
  [ "${#records[@]}" -eq 6 ] || die "version manifest must define six game files"
  for record in "${records[@]}"; do
    IFS=$'\t' read -r id rel vanilla_hash merged_hash <<<"$record"
    is_safe_relative_path "$rel" || die "unsafe game path in version manifest: $rel"
    is_sha256 "$vanilla_hash" && is_sha256 "$merged_hash" ||
      die "invalid game hash in version manifest: $rel"
    data_rels+=("$rel")
    vanilla_hashes+=("$vanilla_hash")
    merged_hashes+=("$merged_hash")
  done

  records_text="$(jq -r '.output_extras[] | [.rel, (.bytes | tostring), .sha256] | @tsv' \
    <<<"$version_json")" || die "could not read external resource records"
  records=()
  if [ -n "$records_text" ]; then
    mapfile -t records <<<"$records_text"
  fi
  for record in "${records[@]}"; do
    IFS=$'\t' read -r rel bytes merged_hash <<<"$record"
    is_safe_relative_path "$rel" || die "unsafe external path in version manifest: $rel"
    [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || die "invalid external size in version manifest: $rel"
    is_sha256 "$merged_hash" || die "invalid external hash in version manifest: $rel"
    external_rels+=("$rel")
    external_bytes+=("$bytes")
    external_hashes+=("$merged_hash")
  done

  load_ralsei_version_manifest

  for index in "${!data_rels[@]}"; do
    expected_backup_rels+=("${data_rels[$index]}")
    expected_backup_hashes+=("${merged_hashes[$index]}")
    expected_backup_ralsei_hashes+=("${ralsei_hashes[$index]}")
  done
  for index in 1 2 3 4 5; do
    expected_backup_rels+=("chapter${index}_windows/data_keucher.win")
    expected_backup_hashes+=("${merged_hashes[$index]}")
    expected_backup_ralsei_hashes+=("${ralsei_hashes[$index]}")
  done
  for index in "${!external_rels[@]}"; do
    expected_backup_rels+=("${external_rels[$index]}")
    expected_backup_hashes+=("${external_hashes[$index]}")
    expected_backup_ralsei_hashes+=("${external_hashes[$index]}")
  done
  while IFS= read -r rel; do
    expected_backup_rels+=("$rel")
    expected_backup_hashes+=("-")
    expected_backup_ralsei_hashes+=("-")
  done < <(jq -er '.audio.outputs[]' <<<"$version_json")

  mapfile -t expected_output_rels < <(jq -er '
    .deltarune.files[].rel, .output_extras[].rel, .audio.outputs[]
  ' <<<"$version_json")
}

add_target() {
  local rel="$1"
  local source="$2"
  local expected_hash="$3"
  local expected_bytes="${4:--}"
  local actual_hash actual_bytes
  is_safe_relative_path "$rel" || die "unsafe output path: $rel"
  is_sha256 "$expected_hash" || die "invalid expected hash for $rel"
  if [ "$expected_bytes" != "-" ]; then
    [[ "$expected_bytes" =~ ^[1-9][0-9]*$ ]] || die "invalid expected size for $rel"
  fi
  [ -z "${target_seen[$rel]+x}" ] || die "duplicate output path: $rel"
  [ -f "$source" ] && [ ! -L "$source" ] || die "missing regular output file: $source"
  actual_bytes="$(stat -c '%s' -- "$source")"
  if [ "$expected_bytes" != "-" ] && [ "$actual_bytes" != "$expected_bytes" ]; then
    die "output size mismatch: $rel (got $actual_bytes, expected $expected_bytes)"
  fi
  actual_hash="$(hash_file "$source")"
  [ "$actual_hash" = "$expected_hash" ] ||
    die "output hash mismatch: $rel (got $actual_hash)"
  target_seen["$rel"]=1
  target_rels+=("$rel")
  target_sources+=("$source")
  target_hashes+=("$expected_hash")
}

validate_audio_file() {
  local source="$1"
  local probe expected_codec expected_sample_rate expected_channels
  local expected_duration actual_duration

  probe="$(ffprobe -v error \
    -show_entries stream=codec_type,codec_name,sample_rate,channels \
    -show_entries format=duration -of json -- "$source")" ||
    die "could not inspect generated audio: $source"
  expected_codec="$(jq -er '.audio.codec' <<<"$version_json")" ||
    die "could not read expected audio codec"
  expected_sample_rate="$(jq -er '.audio.sample_rate' <<<"$version_json")" ||
    die "could not read expected audio sample rate"
  expected_channels="$(jq -er '.audio.channels' <<<"$version_json")" ||
    die "could not read expected audio channel count"
  expected_duration="$(jq -er '.audio.duration' <<<"$version_json")" ||
    die "could not read expected audio duration"

  jq -e --arg codec "$expected_codec" \
    --arg sample_rate "$expected_sample_rate" \
    --argjson channels "$expected_channels" '
      (.streams | length) == 1 and
      .streams[0].codec_type == "audio" and
      .streams[0].codec_name == $codec and
      ((.streams[0].sample_rate | tonumber) == ($sample_rate | tonumber)) and
      ((.streams[0].channels | tonumber) == $channels) and
      ((.format.duration | tonumber) > 0)
    ' <<<"$probe" >/dev/null || die "generated audio properties do not match the version lock: $source"
  actual_duration="$(jq -er '.format.duration | tonumber' <<<"$probe")" ||
    die "could not read generated audio duration: $source"
  awk -v actual="$actual_duration" -v expected="$expected_duration" '
    BEGIN {
      delta = actual - expected
      if (delta < 0) delta = -delta
      exit(delta > 0.001)
    }
  ' || die "generated audio duration does not match the version lock: $source"

  local fingerprint_output actual_fingerprint expected_fingerprint
  local fingerprint_seconds minimum_similarity similarity
  fingerprint_seconds="$(jq -er '.audio.fingerprint_seconds' <<<"$version_json")" ||
    die "could not read audio fingerprint length"
  minimum_similarity="$(jq -er '.audio.fingerprint_min_similarity' <<<"$version_json")" ||
    die "could not read audio fingerprint threshold"
  expected_fingerprint="$(jq -er '.audio.fingerprint_raw' <<<"$version_json")" ||
    die "could not read locked audio fingerprint"
  fingerprint_output="$(fpcalc -raw -length "$fingerprint_seconds" "$source")" ||
    die "could not calculate the audio fingerprint: $source"
  actual_fingerprint="$(awk -F= '$1 == "FINGERPRINT" {print substr($0, index($0, "=") + 1)}' \
    <<<"$fingerprint_output")"
  [[ "$actual_fingerprint" =~ ^[0-9]+(,[0-9]+)+$ ]] ||
    die "fpcalc returned an invalid fingerprint: $source"
  similarity="$(gawk \
    -v expected="$expected_fingerprint" \
    -v actual="$actual_fingerprint" '
    function bit_count(value, count, i) {
      for (i = 0; i < 32; i++) {
        count += and(value, 1)
        value = rshift(value, 1)
      }
      return count
    }
    BEGIN {
      expected_count = split(expected, expected_values, ",")
      actual_count = split(actual, actual_values, ",")
      if (expected_count != actual_count || expected_count == 0) exit 2
      different_bits = 0
      for (i = 1; i <= expected_count; i++)
        different_bits += bit_count(xor(expected_values[i] + 0, actual_values[i] + 0))
      printf "%.9f", 1 - (different_bits / (expected_count * 32))
    }
  ')" || die "audio fingerprint length does not match the version lock: $source"
  awk -v actual="$similarity" -v minimum="$minimum_similarity" \
    'BEGIN { exit(actual + 0 < minimum + 0) }' ||
    die "audio content fingerprint does not match the locked source: $source (similarity $similarity)"
}

check_destination_path() {
  local game="$1"
  local rel="$2"
  local parent component accumulated=""
  local -a components=()

  parent="${rel%/*}"
  if [ "$parent" != "$rel" ]; then
    IFS='/' read -r -a components <<<"$parent"
    for component in "${components[@]}"; do
      if [ -n "$accumulated" ]; then
        accumulated+="/$component"
      else
        accumulated="$component"
      fi
      if [ -L "$game/$accumulated" ]; then
        die "destination parent is a symlink: $game/$accumulated"
      elif [ -e "$game/$accumulated" ]; then
        [ -d "$game/$accumulated" ] || die "destination parent is not a directory: $game/$accumulated"
      elif [ -z "${created_dir_seen[$accumulated]+x}" ]; then
        created_dir_seen["$accumulated"]=1
        created_dirs+=("$accumulated")
      fi
    done
  fi

  if [ -L "$game/$rel" ]; then
    die "destination is a symlink: $game/$rel"
  elif [ -e "$game/$rel" ] && [ ! -f "$game/$rel" ]; then
    die "destination is not a regular file: $game/$rel"
  elif [ -f "$game/$rel" ] && [ "$(stat -c '%h' -- "$game/$rel")" -gt 1 ]; then
    die "destination is hard-linked and cannot be restored exactly: $game/$rel"
  fi
}

verify_exact_output_tree() {
  local out="$1" expected_tree actual_tree
  expected_tree="$({
    printf '%s\n' "${expected_output_rels[@]}"
    printf '%s\n' build-info.json
  } | awk '
    NF {
      print "f " $0
      path = $0
      while (sub("/[^/]+$", "", path)) print "d " path
    }
  ' | LC_ALL=C sort -u)"
  actual_tree="$(find "$out" -xdev -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort)" ||
    die "could not enumerate output directory: $out"
  [ "$actual_tree" = "$expected_tree" ] ||
    die "output contains a missing, unexpected, or unsafe tree entry: $out"
}

build_target_list() {
  local out="$1"
  local index source rel expected_outputs expected_provenance build_info_json schema
  local audio_records_text generated_audio_hash generated_audio_bytes canonical_audio=""
  local -a audio_rels=()

  source_path_is_safe "$out" "build-info.json" ||
    die "missing build metadata: $out/build-info.json"
  build_info_json="$(<"$out/build-info.json")"
  expected_outputs="$(jq -ce '[.deltarune.files[] | {rel, sha256: .output_sha256}]' \
    <<<"$version_json")" || die "could not read expected output records"
  expected_provenance="$(jq -ce '{
      upstreams: .upstreams,
      adapters: .adapters,
      undertale_mod_cli: .tools.undertale_mod_cli,
      audio: .audio
    }' <<<"$version_json")" || die "could not read expected build provenance"
  jq -e --arg build_id "$build_id" \
    --argjson expected_outputs "$expected_outputs" \
    --argjson ralsei_outputs "$ralsei_expected_outputs_json" \
    --argjson expected_variant "$ralsei_variant_json" \
    --argjson expected_provenance "$expected_provenance" '
    type == "object" and
    ((
      (keys | sort) == [
        "build_id", "built_at", "environment", "generated_audio",
        "outputs", "provenance", "schema"
      ] and .schema == 2 and .outputs == $expected_outputs
    ) or (
      (keys | sort) == [
        "build_id", "built_at", "environment", "generated_audio",
        "outputs", "provenance", "schema", "variant"
      ] and .schema == 3 and .outputs == $ralsei_outputs and
      .variant == $expected_variant
    )) and
    .build_id == $build_id and .provenance == $expected_provenance and
    (.built_at | type == "string" and length > 0) and
    (.environment | type == "object") and
    (.environment | keys | sort) == ["dotnet", "ffmpeg", "wine"] and
    all(.environment[]; type == "string" and length > 0) and
    (.generated_audio | type == "object") and
    (.generated_audio | keys | sort) == ["bytes", "sha256"] and
    (.generated_audio.bytes | type == "number" and isfinite and floor == . and . > 0) and
    (.generated_audio.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' <<<"$build_info_json" >/dev/null ||
    die "output build metadata does not match version $build_id"
  generated_audio_hash="$(jq -er '.generated_audio.sha256' <<<"$build_info_json")" ||
    die "could not read generated audio hash"
  generated_audio_bytes="$(jq -er '.generated_audio.bytes' <<<"$build_info_json")" ||
    die "could not read generated audio size"

  schema="$(jq -er '.schema' <<<"$build_info_json")" ||
    die "could not read output metadata schema"
  if [ "$schema" = 3 ]; then
    selected_hashes=("${ralsei_hashes[@]}")
    selected_bytes=("${ralsei_bytes[@]}")
  else
    selected_hashes=("${merged_hashes[@]}")
    selected_bytes=()
    for index in "${!merged_hashes[@]}"; do
      selected_bytes+=("-")
    done
  fi

  for index in "${!data_rels[@]}"; do
    source="$out/${data_rels[$index]}"
    source_path_is_safe "$out" "${data_rels[$index]}" ||
      die "missing or unsafe output file: $source"
    add_target "${data_rels[$index]}" "$source" \
      "${selected_hashes[$index]}" "${selected_bytes[$index]}"
  done

  for index in 1 2 3 4 5; do
    source_path_is_safe "$out" "chapter${index}_windows/data.win" ||
      die "missing or unsafe output file: $out/chapter${index}_windows/data.win"
    add_target "chapter${index}_windows/data_keucher.win" \
      "$out/chapter${index}_windows/data.win" \
      "${selected_hashes[$index]}" "${selected_bytes[$index]}"
  done

  for index in "${!external_rels[@]}"; do
    rel="${external_rels[$index]}"
    source_path_is_safe "$out" "$rel" || die "missing or unsafe external resource: $out/$rel"
    add_target "$rel" "$out/$rel" "${external_hashes[$index]}" "${external_bytes[$index]}"
  done
  audio_records_text="$(jq -er '.audio.outputs[] | [.] | @tsv' <<<"$version_json")" ||
    die "could not read generated audio paths"
  mapfile -t audio_rels <<<"$audio_records_text"
  [ "${#audio_rels[@]}" -gt 0 ] || die "version manifest defines no audio outputs"
  for rel in "${audio_rels[@]}"; do
    is_safe_relative_path "$rel" || die "unsafe audio output path in version manifest: $rel"
    source_path_is_safe "$out" "$rel" || die "missing or unsafe audio resource: $out/$rel"
    add_target "$rel" "$out/$rel" "$generated_audio_hash" "$generated_audio_bytes"
    if [ -z "$canonical_audio" ]; then
      canonical_audio="$out/$rel"
    else
      cmp -s -- "$canonical_audio" "$out/$rel" || die "generated audio copies differ: $rel"
    fi
  done
  validate_audio_file "$canonical_audio"
  verify_exact_output_tree "$out"
}

validate_game_data() {
  local game="$1"
  local vanilla_count=0 merged_count=0 ralsei_count=0 index actual

  for index in "${!data_rels[@]}"; do
    [ -f "$game/${data_rels[$index]}" ] && [ ! -L "$game/${data_rels[$index]}" ] ||
      die "missing regular game file: $game/${data_rels[$index]}"
    actual="$(hash_file "$game/${data_rels[$index]}")"
    if [ "$actual" = "${vanilla_hashes[$index]}" ]; then
      vanilla_count=$((vanilla_count + 1))
    elif [ "$actual" = "${merged_hashes[$index]}" ]; then
      merged_count=$((merged_count + 1))
    fi
    if [ "$actual" = "${ralsei_hashes[$index]}" ]; then
      ralsei_count=$((ralsei_count + 1))
    fi
    if [ "$actual" != "${vanilla_hashes[$index]}" ] &&
      [ "$actual" != "${merged_hashes[$index]}" ] &&
      [ "$actual" != "${ralsei_hashes[$index]}" ]; then
      die "unknown game file: ${data_rels[$index]} (sha256 $actual)"
    fi
  done

  if [ "$vanilla_count" -eq "${#data_rels[@]}" ]; then
    echo "game data: exact vanilla $game_version"
  elif [ "$merged_count" -eq "${#data_rels[@]}" ]; then
    echo "game data: exact base merged output"
  elif [ "$ralsei_count" -eq "${#data_rels[@]}" ]; then
    echo "game data: exact Ralsei portrait variant"
  else
    die "game data files are a mixture of vanilla, base, or Ralsei variants; refusing to write"
  fi
}

acquire_lock() {
  local game="$1"
  lock_dir="$game/.dr-tas-chs-install.lock"
  mkdir -- "$lock_dir" 2>/dev/null || die "another install/restore may be running: $lock_dir"
  lock_owned=1
}

create_unique_backup() {
  local game="$1"
  local backups="$root/backups"
  local base attempt=0
  paths_overlap "$game" "$backups" &&
    die "backup directory must be outside the game directory: $backups"
  mkdir -p -- "$backups"
  backups="$(canonical_dir "$backups")"
  paths_overlap "$game" "$backups" &&
    die "backup directory must be outside the game directory: $backups"
  base="$backups/DELTARUNE-$(date +%Y%m%d-%H%M%S)"
  backup_dir="$base"
  while :; do
    if mkdir -- "$backup_dir" 2>/dev/null; then
      break
    elif [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
      attempt=$((attempt + 1))
      backup_dir="$base-$attempt"
    else
      die "could not create backup directory: $backup_dir"
    fi
  done
  mkdir -- "$backup_dir/files"
}

atomic_write_line() {
  local destination="$1"
  local value="$2"
  local parent temp
  parent="${destination%/*}"
  temp="$(mktemp "$parent/.dr-tas-chs-metadata.XXXXXX")" || return 1
  if ! printf '%s\n' "$value" >"$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if ! mv -f -- "$temp" "$destination"; then
    rm -f -- "$temp"
    return 1
  fi
  return 0
}

copy_file_atomically() {
  local source="$1"
  local destination="$2"
  local parent temp
  parent="${destination%/*}"
  mkdir -p -- "$parent" || return 1
  temp="$(mktemp "$parent/.dr-tas-chs-file.XXXXXX")" || return 1
  if ! cp -a -- "$source" "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if ! mv -f -- "$temp" "$destination"; then
    rm -f -- "$temp"
    return 1
  fi
  return 0
}

copy_backup_from_fd_atomically() {
  local source_ref="$1"
  local destination="$2"
  local expected_mode="$3"
  local expected_hash="$4"
  local parent temp actual_hash actual_mode actual_links
  parent="${destination%/*}"
  mkdir -p -- "$parent" || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  temp="$(mktemp "$parent/.dr-tas-chs-backup.XXXXXX")" || return 1
  if ! cp -aL -- "$source_ref" "$temp"; then
    rm -f -- "$temp"
    return 1
  fi
  if [ ! -f "$temp" ] || [ -L "$temp" ]; then
    rm -f -- "$temp"
    return 1
  fi
  actual_links="$(stat -c '%h' -- "$temp")" || {
    rm -f -- "$temp"
    return 1
  }
  actual_mode="$(stat -c '%a' -- "$temp")" || {
    rm -f -- "$temp"
    return 1
  }
  actual_hash="$(hash_file "$temp")" || {
    rm -f -- "$temp"
    return 1
  }
  if [ "$actual_links" -ne 1 ] || [ "$actual_mode" != "$expected_mode" ] ||
    [ "$actual_hash" != "$expected_hash" ]; then
    rm -f -- "$temp"
    return 1
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    rm -f -- "$temp"
    return 1
  fi
  if ! mv -f -T -- "$temp" "$destination"; then
    rm -f -- "$temp"
    return 1
  fi
  [ -f "$destination" ] && [ ! -L "$destination" ] &&
    [ "$(stat -c '%h' -- "$destination")" -eq 1 ] &&
    [ "$(stat -c '%a' -- "$destination")" = "$expected_mode" ] &&
    [ "$(hash_file "$destination")" = "$expected_hash" ]
}

open_regular_single_link() {
  local path="$1" result_var="$2" opened_fd fd_ref path_identity fd_identity
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  exec {opened_fd}<"$path" || return 1
  fd_ref="/proc/$$/fd/$opened_fd"
  if [ ! -f "$fd_ref" ] || [ "$(stat -Lc '%h' -- "$fd_ref")" -ne 1 ]; then
    exec {opened_fd}<&-
    return 1
  fi
  path_identity="$(stat -Lc '%d:%i' -- "$path")" || {
    exec {opened_fd}<&-
    return 1
  }
  fd_identity="$(stat -Lc '%d:%i' -- "$fd_ref")" || {
    exec {opened_fd}<&-
    return 1
  }
  if [ "$path_identity" != "$fd_identity" ]; then
    exec {opened_fd}<&-
    return 1
  fi
  printf -v "$result_var" '%s' "$opened_fd"
}

file_descriptor_still_matches() {
  local path="$1" fd="$2"
  local fd_ref="/proc/$$/fd/$fd"
  [ -f "$path" ] && [ ! -L "$path" ] && [ -f "$fd_ref" ] &&
    [ "$(stat -Lc '%h' -- "$fd_ref")" -eq 1 ] &&
    [ "$(stat -Lc '%d:%i' -- "$path")" = "$(stat -Lc '%d:%i' -- "$fd_ref")" ]
}

move_staged_file_atomically() {
  local source="$1"
  local destination="$2"
  local parent
  [ -f "$source" ] && [ ! -L "$source" ] && [ "$(stat -c '%h' -- "$source")" -eq 1 ] ||
    return 1
  parent="${destination%/*}"
  mkdir -p -- "$parent" || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  [ "$(stat -c '%d' -- "$source")" = "$(stat -Lc '%d' -- "$parent")" ] || return 1
  mv -f -T -- "$source" "$destination"
}

remove_created_dirs() {
  local game="$1"
  shift
  local -a dirs=("$@")
  local index
  for ((index = ${#dirs[@]} - 1; index >= 0; index--)); do
    if destination_parent_is_safe "$game" "${dirs[$index]}" &&
      [ -d "$game/${dirs[$index]}" ] && [ ! -L "$game/${dirs[$index]}" ]; then
      rmdir -- "$game/${dirs[$index]}" 2>/dev/null || true
    fi
  done
}

rollback_apply() {
  local game="$1"
  local index state rel current_hash rollback_source
  local rollback_failed=0
  echo "install failed; restoring the pre-install state" >&2
  for index in "${apply_written_indices[@]}"; do
    state="${apply_states[$index]}"
    rel="${target_rels[$index]}"
    if ! destination_parent_is_safe "$game" "$rel"; then
      echo "rollback refused an unsafe destination parent for $rel" >&2
      rollback_failed=1
      continue
    fi
    case "$state" in
      existing)
        rollback_source="$stage_dir/rollback/$rel"
        if [ -f "$game/$rel" ] && [ ! -L "$game/$rel" ]; then
          current_hash="$(hash_file "$game/$rel" 2>/dev/null)"
          if [ "$current_hash" != "${apply_original_hashes[$index]}" ] &&
            [ "$current_hash" != "${target_hashes[$index]}" ]; then
            echo "rollback preserved concurrently changed file $rel" >&2
            rollback_failed=1
            continue
          fi
        elif [ -e "$game/$rel" ] || [ -L "$game/$rel" ]; then
          echo "rollback preserved unexpected state for $rel" >&2
          rollback_failed=1
          continue
        fi
        if [ -f "$game/$rel" ] && [ "$current_hash" = "${apply_original_hashes[$index]}" ]; then
          continue
        fi
        if [ -f "$rollback_source" ] && [ ! -L "$rollback_source" ] &&
          [ "$(hash_file "$rollback_source" 2>/dev/null)" = "${apply_original_hashes[$index]}" ]; then
          if ! move_staged_file_atomically "$rollback_source" "$game/$rel" ||
            [ "$(hash_file "$game/$rel" 2>/dev/null)" != "${apply_original_hashes[$index]}" ]; then
            echo "rollback failed for $rel" >&2
            rollback_failed=1
          fi
          continue
        fi
        if ! rm -f -- "$game/$rel" || ! copy_file_atomically "$backup_dir/files/$rel" "$game/$rel" ||
          [ "$(hash_file "$game/$rel" 2>/dev/null)" != "${apply_original_hashes[$index]}" ]; then
          echo "rollback failed for $rel" >&2
          rollback_failed=1
        fi
        ;;
      missing)
        if [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ]; then
          continue
        elif [ ! -f "$game/$rel" ] || [ -L "$game/$rel" ] ||
          [ "$(hash_file "$game/$rel" 2>/dev/null)" != "${target_hashes[$index]}" ]; then
          echo "rollback preserved concurrently changed file $rel" >&2
          rollback_failed=1
          continue
        fi
        if ! rm -f -- "$game/$rel" || [ -e "$game/$rel" ] || [ -L "$game/$rel" ]; then
          echo "rollback failed for $rel" >&2
          rollback_failed=1
        fi
        ;;
    esac
  done
  remove_created_dirs "$game" "${apply_created_dirs[@]}"
  if [ "$rollback_failed" -eq 0 ]; then
    atomic_write_line "$backup_dir/status" "ROLLED_BACK" 2>/dev/null ||
      echo "warning: could not update rollback status in $backup_dir" >&2
  else
    atomic_write_line "$backup_dir/status" "ROLLBACK_FAILED" 2>/dev/null || true
    echo "manual recovery is required; backup: $backup_dir" >&2
  fi
}

declare -a restore_states=()
declare -a restore_original_hashes=()
declare -a restore_installed_hashes=()
declare -a restore_rels=()
declare -a restore_actions=()
declare -a restore_current_existed=()
declare -a restore_current_hashes=()
declare -a restore_created_dirs=()
declare -a restore_made_dirs=()
declare -a restore_written_indices=()
declare -a restore_original_missing_dirs=()

rollback_restore() {
  local game="$1"
  local index rel current_hash action
  local rollback_failed=0
  echo "restore failed; returning to the pre-restore state" >&2
  for index in "${restore_written_indices[@]}"; do
    rel="${restore_rels[$index]}"
    if ! destination_parent_is_safe "$game" "$rel"; then
      echo "restore rollback refused an unsafe destination parent for $rel" >&2
      rollback_failed=1
      continue
    fi
    action="${restore_actions[$index]}"
    if [ "${restore_current_existed[$index]}" = "1" ]; then
      if [ -f "$game/$rel" ] && [ ! -L "$game/$rel" ]; then
        current_hash="$(hash_file "$game/$rel" 2>/dev/null)"
        if [ "$current_hash" != "${restore_current_hashes[$index]}" ] &&
          { [ "$action" != "restore" ] ||
            [ "$current_hash" != "${restore_original_hashes[$index]}" ]; }; then
          echo "restore rollback preserved concurrently changed file $rel" >&2
          rollback_failed=1
          continue
        fi
      elif [ "$action" != "remove" ] || [ -e "$game/$rel" ] || [ -L "$game/$rel" ]; then
        echo "restore rollback preserved unexpected state for $rel" >&2
        rollback_failed=1
        continue
      fi
      if ! move_staged_file_atomically "$stage_dir/current/$rel" "$game/$rel" ||
        [ "$(hash_file "$game/$rel" 2>/dev/null)" != "${restore_current_hashes[$index]}" ]; then
        echo "restore rollback failed for $rel" >&2
        rollback_failed=1
      fi
    else
      if [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ]; then
        continue
      elif [ "$action" != "restore" ] || [ ! -f "$game/$rel" ] || [ -L "$game/$rel" ] ||
        [ "$(hash_file "$game/$rel" 2>/dev/null)" != "${restore_original_hashes[$index]}" ]; then
        echo "restore rollback preserved concurrently changed file $rel" >&2
        rollback_failed=1
        continue
      fi
      if ! rm -f -- "$game/$rel" || [ -e "$game/$rel" ] || [ -L "$game/$rel" ]; then
        echo "restore rollback failed for $rel" >&2
        rollback_failed=1
      fi
    fi
  done
  remove_created_dirs "$game" "${restore_made_dirs[@]}"
  if [ "$rollback_failed" -ne 0 ]; then
    preserve_stage=1
    echo "manual recovery is required; backup: $backup_dir" >&2
    echo "pre-restore snapshots were preserved at: $stage_dir/current" >&2
  fi
}

on_exit() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$writes_started" -eq 1 ]; then
    if [ "$operation" = "apply" ]; then
      if [ -n "$stage_dir" ] && [ -d "$stage_dir/files" ] && [ ! -L "$stage_dir/files" ]; then
        rm -rf --one-file-system -- "$stage_dir/files"
      fi
      rollback_apply "$active_game"
    elif [ "$operation" = "restore" ]; then
      rollback_restore "$active_game"
    fi
  fi
  if [ "$preserve_stage" -eq 0 ] && [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    rm -rf --one-file-system -- "$stage_dir"
  fi
  if [ "$lock_owned" -eq 1 ] && [ -n "$lock_dir" ] && [ -d "$lock_dir" ]; then
    rmdir -- "$lock_dir" 2>/dev/null || true
  fi
  if [ -n "$latest_tmp" ]; then
    rm -f -- "$latest_tmp"
  fi
  exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

apply_output() {
  local game="$1"
  local out="$2"
  local index rel destination source expected actual state original_hash backup_umask
  local all_installed=1 source_fd source_ref original_mode backup_target

  operation="apply"
  active_game="$game"
  acquire_lock "$game"
  build_target_list "$out"
  validate_game_data "$game"

  for index in "${!target_rels[@]}"; do
    rel="${target_rels[$index]}"
    check_destination_path "$game" "$rel"
    destination="$game/$rel"
    if [ ! -f "$destination" ] || [ -L "$destination" ] ||
      [ "$(hash_file "$destination")" != "${target_hashes[$index]}" ]; then
      all_installed=0
    fi
  done
  if [ "$all_installed" -eq 1 ]; then
    echo "TAS+CHS output is already fully installed in $game"
    return
  fi

  backup_umask="$(umask)"
  umask 077
  create_unique_backup "$game"
  printf '1\n' >"$backup_dir/manifest.version"
  printf '%s\n' "$build_id" >"$backup_dir/build_id.txt"
  printf '%s\n' "$game" >"$backup_dir/game_dir.txt"
  : >"$backup_dir/manifest.tsv"
  : >"$backup_dir/dirs.tsv"
  for rel in "${created_dirs[@]}"; do
    printf '%s\n' "$rel" >>"$backup_dir/dirs.tsv"
  done

  for index in "${!target_rels[@]}"; do
    rel="${target_rels[$index]}"
    destination="$game/$rel"
    destination_parent_is_safe_or_missing "$game" "$rel" ||
      die "unsafe destination parent while creating backup: $rel"
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
      die "destination changed to an unsafe file while creating backup: $rel"
    fi
    if [ -f "$destination" ]; then
      state="existing"
      open_regular_single_link "$destination" source_fd ||
        die "destination changed while opening backup source: $rel"
      source_ref="/proc/$$/fd/$source_fd"
      original_hash="$(hash_file "$source_ref")"
      original_mode="$(stat -Lc '%a' -- "$source_ref")"
      backup_target="$backup_dir/files/$rel"
      if ! copy_backup_from_fd_atomically \
        "$source_ref" "$backup_target" "$original_mode" "$original_hash"; then
        exec {source_fd}<&-
        die "backup copy or verification failed: $rel"
      fi
      if ! file_descriptor_still_matches "$destination" "$source_fd"; then
        exec {source_fd}<&-
        die "destination changed while it was backed up: $rel"
      fi
      exec {source_fd}<&-
    else
      state="missing"
      original_hash="-"
    fi
    apply_states+=("$state")
    apply_original_hashes+=("$original_hash")
    printf '%s\t%s\t%s\t%s\n' "$state" "$original_hash" \
      "${target_hashes[$index]}" "$rel" >>"$backup_dir/manifest.tsv"
  done
  validate_game_data "$game" >/dev/null
  printf '%s\n' "${#target_rels[@]}" >"$backup_dir/target_count"
  atomic_write_line "$backup_dir/status" "READY"
  umask "$backup_umask"

  stage_dir="$(mktemp -d "$game/.dr-tas-chs-stage.XXXXXX")"
  for index in "${!target_rels[@]}"; do
    rel="${target_rels[$index]}"
    source="${target_sources[$index]}"
    mkdir -p -- "$stage_dir/files/$(relative_parent "$rel")"
    cp -a -- "$source" "$stage_dir/files/$rel"
    actual="$(hash_file "$stage_dir/files/$rel")"
    [ "$actual" = "${target_hashes[$index]}" ] || die "staging verification failed: $rel"
  done

  latest_tmp="$(mktemp "$root/.latest_backup.XXXXXX")"
  printf '%s\n' "$backup_dir" >"$latest_tmp"
  atomic_write_line "$backup_dir/status" "APPLYING"
  writes_started=1
  for rel in "${created_dirs[@]}"; do
    destination_parent_is_safe "$game" "$rel" ||
      die "unsafe destination parent during install: $game/$rel"
    [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ] ||
      die "destination changed during install: $game/$rel"
    index="${#apply_created_dirs[@]}"
    apply_created_dirs+=("$rel")
    if ! mkdir -- "$game/$rel"; then
      unset 'apply_created_dirs[index]'
      die "could not create destination directory: $game/$rel"
    fi
  done
  for index in "${!target_rels[@]}"; do
    rel="${target_rels[$index]}"
    destination_parent_is_safe "$game" "$rel" ||
      die "unsafe destination parent during install: $game/$rel"
    if [ "${apply_states[$index]}" = "existing" ]; then
      [ -f "$game/$rel" ] && [ ! -L "$game/$rel" ] &&
        [ "$(hash_file "$game/$rel")" = "${apply_original_hashes[$index]}" ] ||
        die "destination changed during install: $game/$rel"
    else
      [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ] ||
        die "destination changed during install: $game/$rel"
    fi
    apply_written_indices+=("$index")
    if [ "${apply_states[$index]}" = "existing" ]; then
      mkdir -p -- "$stage_dir/rollback/$(relative_parent "$rel")"
      ln -- "$game/$rel" "$stage_dir/rollback/$rel" ||
        die "could not link destination for rollback: $rel"
      [ "$(hash_file "$stage_dir/rollback/$rel")" = "${apply_original_hashes[$index]}" ] ||
        die "rollback link verification failed: $rel"
    fi
    move_staged_file_atomically "$stage_dir/files/$rel" "$game/$rel" ||
      die "could not atomically install file: $rel"
    actual="$(hash_file "$game/$rel")"
    [ "$actual" = "${target_hashes[$index]}" ] || die "installed file verification failed: $rel"
  done

  atomic_write_line "$backup_dir/status" "APPLIED"
  mv -f -- "$latest_tmp" "$root/latest_backup.txt"
  latest_tmp=""
  writes_started=0
  echo "installed TAS+CHS output to $game"
  echo "backup: $backup_dir"
}

dir_is_manifest_parent() {
  local dir="$1"
  local rel
  for rel in "${restore_rels[@]}"; do
    [[ "$rel" == "$dir/"* ]] && return 0
  done
  return 1
}

validate_backup_tree() {
  local backup="$1"
  local index entry parent expected_tree actual_tree linked_file
  local -A expected=(
    ["f manifest.version"]=1
    ["f build_id.txt"]=1
    ["f game_dir.txt"]=1
    ["f manifest.tsv"]=1
    ["f dirs.tsv"]=1
    ["f target_count"]=1
    ["f status"]=1
    ["d files"]=1
  )

  for index in "${!restore_rels[@]}"; do
    [ "${restore_states[$index]}" = "existing" ] || continue
    entry="files/${restore_rels[$index]}"
    expected["f $entry"]=1
    parent="${entry%/*}"
    while [ "$parent" != "$entry" ]; do
      expected["d $parent"]=1
      entry="$parent"
      parent="${entry%/*}"
    done
  done

  linked_file="$(find "$backup" -xdev -type f ! -links 1 -print -quit)"
  [ -z "$linked_file" ] || die "backup contains a hard-linked file: $linked_file"
  expected_tree="$(printf '%s\n' "${!expected[@]}" | LC_ALL=C sort)"
  actual_tree="$(find "$backup" -xdev -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort)"
  [ "$actual_tree" = "$expected_tree" ] ||
    die "backup contains a missing, unexpected, or unsafe tree entry: $backup"
}

load_and_validate_backup() {
  local game="$1"
  local backup="$2"
  local state original_hash installed_hash rel extra actual expected_count recorded_game
  local recorded_build status index base_expected ralsei_expected row_profile
  local installed_profile=""
  local -A seen=()
  local -A expected_hash_by_rel=()
  local -A expected_ralsei_hash_by_rel=()
  local -A dir_seen=()
  local count=0

  [ -f "$backup/manifest.version" ] && [ ! -L "$backup/manifest.version" ] &&
    [ "$(<"$backup/manifest.version")" = "1" ] ||
    die "unsupported or incomplete backup: $backup"
  [ -f "$backup/build_id.txt" ] && [ ! -L "$backup/build_id.txt" ] ||
    die "backup has no build id: $backup"
  recorded_build="$(<"$backup/build_id.txt")"
  [ "$recorded_build" = "$build_id" ] ||
    die "backup belongs to a different build: $recorded_build"
  [ -f "$backup/status" ] && [ ! -L "$backup/status" ] ||
    die "backup has no valid status: $backup"
  status="$(<"$backup/status")"
  [ "$status" = "APPLYING" ] || [ "$status" = "APPLIED" ] ||
    [ "$status" = "RESTORED" ] ||
    die "backup is not in a restorable state: $status"
  [ -f "$backup/game_dir.txt" ] && [ ! -L "$backup/game_dir.txt" ] ||
    die "backup has no game directory record: $backup"
  recorded_game="$(<"$backup/game_dir.txt")"
  [ "$recorded_game" = "$game" ] ||
    die "backup belongs to a different game directory: $recorded_game"
  [ -d "$backup/files" ] && [ ! -L "$backup/files" ] &&
    [ -f "$backup/manifest.tsv" ] && [ ! -L "$backup/manifest.tsv" ] &&
    [ -f "$backup/dirs.tsv" ] && [ ! -L "$backup/dirs.tsv" ] &&
    [ -f "$backup/target_count" ] && [ ! -L "$backup/target_count" ] ||
    die "incomplete backup metadata: $backup"
  expected_count="$(<"$backup/target_count")"
  [[ "$expected_count" =~ ^[0-9]+$ ]] || die "invalid backup target count"
  [ "$expected_count" -eq "${#expected_backup_rels[@]}" ] ||
    die "backup target set does not match build $build_id"
  for index in "${!expected_backup_rels[@]}"; do
    expected_hash_by_rel["${expected_backup_rels[$index]}"]="${expected_backup_hashes[$index]}"
    expected_ralsei_hash_by_rel["${expected_backup_rels[$index]}"]="${expected_backup_ralsei_hashes[$index]}"
  done

  while IFS=$'\t' read -r state original_hash installed_hash rel extra; do
    [ -z "${extra:-}" ] || die "invalid backup manifest row"
    is_safe_relative_path "$rel" || die "unsafe path in backup: $rel"
    [ -z "${seen[$rel]+x}" ] || die "duplicate path in backup: $rel"
    [ -n "${expected_hash_by_rel[$rel]+x}" ] || die "unexpected path in backup: $rel"
    seen["$rel"]=1
    is_sha256 "$installed_hash" || die "invalid installed hash in backup: $rel"
    base_expected="${expected_hash_by_rel[$rel]}"
    ralsei_expected="${expected_ralsei_hash_by_rel[$rel]}"
    row_profile=""
    if [ "$base_expected" = "-" ] && [ "$ralsei_expected" = "-" ]; then
      :
    elif [ "$base_expected" = "$ralsei_expected" ]; then
      [ "$installed_hash" = "$base_expected" ] ||
        die "installed hash in backup does not match build $build_id: $rel"
    elif [ "$installed_hash" = "$base_expected" ]; then
      row_profile="base"
    elif [ "$installed_hash" = "$ralsei_expected" ]; then
      row_profile="ralsei_portraits"
    else
      die "installed hash in backup does not match a known build variant: $rel"
    fi
    if [ -n "$row_profile" ]; then
      if [ -n "$installed_profile" ] && [ "$installed_profile" != "$row_profile" ]; then
        die "backup contains a mixture of base and Ralsei portrait outputs"
      fi
      installed_profile="$row_profile"
    fi
    case "$state" in
      existing)
        is_sha256 "$original_hash" || die "invalid original hash in backup: $rel"
        source_path_is_safe "$backup/files" "$rel" ||
          die "missing original file in backup: $rel"
        actual="$(hash_file "$backup/files/$rel")"
        [ "$actual" = "$original_hash" ] || die "corrupt original file in backup: $rel"
        ;;
      missing)
        [ "$original_hash" = "-" ] || die "invalid missing-file record: $rel"
        [ ! -e "$backup/files/$rel" ] && [ ! -L "$backup/files/$rel" ] ||
          die "unexpected file in backup: $rel"
        ;;
      *) die "invalid state in backup for $rel: $state" ;;
    esac
    restore_states+=("$state")
    restore_original_hashes+=("$original_hash")
    restore_installed_hashes+=("$installed_hash")
    restore_rels+=("$rel")
    count=$((count + 1))
  done <"$backup/manifest.tsv"
  [ "$count" -eq "$expected_count" ] && [ "$count" -gt 0 ] ||
    die "backup target count mismatch"
  [ -n "$installed_profile" ] || die "backup does not identify a known output variant"
  for rel in "${expected_backup_rels[@]}"; do
    [ -n "${seen[$rel]+x}" ] || die "backup is missing target: $rel"
  done

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    is_safe_relative_path "$rel" || die "unsafe directory in backup: $rel"
    [ -z "${dir_seen[$rel]+x}" ] || die "duplicate directory in backup: $rel"
    dir_seen["$rel"]=1
    dir_is_manifest_parent "$rel" || die "unrelated directory in backup: $rel"
    restore_original_missing_dirs+=("$rel")
  done <"$backup/dirs.tsv"
  validate_backup_tree "$backup"
}

collect_restore_parents() {
  local game="$1"
  local rel parent component accumulated index
  local -a components=()
  local -A seen=()

  for index in "${!restore_rels[@]}"; do
    [ "${restore_actions[$index]}" = "restore" ] || continue
    rel="${restore_rels[$index]}"
    parent="${rel%/*}"
    [ "$parent" != "$rel" ] || continue
    accumulated=""
    IFS='/' read -r -a components <<<"$parent"
    for component in "${components[@]}"; do
      if [ -n "$accumulated" ]; then
        accumulated+="/$component"
      else
        accumulated="$component"
      fi
      if [ -L "$game/$accumulated" ]; then
        die "destination parent is a symlink: $game/$accumulated"
      elif [ -e "$game/$accumulated" ]; then
        [ -d "$game/$accumulated" ] || die "destination parent is not a directory: $game/$accumulated"
      elif [ -z "${seen[$accumulated]+x}" ]; then
        seen["$accumulated"]=1
        restore_created_dirs+=("$accumulated")
      fi
    done
  done
}

restore_backup() {
  local game="$1"
  local backup="$2"
  local index rel destination state current_hash action any_changes=0

  operation="restore"
  active_game="$game"
  acquire_lock "$game"
  load_and_validate_backup "$game" "$backup"
  backup_dir="$backup"

  for index in "${!restore_rels[@]}"; do
    rel="${restore_rels[$index]}"
    state="${restore_states[$index]}"
    destination="$game/$rel"
    check_destination_path "$game" "$rel"
    if [ -f "$destination" ]; then
      current_hash="$(hash_file "$destination")"
      if [ "$state" = "existing" ] &&
        [ "$current_hash" = "${restore_original_hashes[$index]}" ]; then
        action="skip"
      elif [ "$state" = "existing" ] &&
        [ "$current_hash" = "${restore_installed_hashes[$index]}" ]; then
        action="restore"
      elif [ "$state" = "missing" ] &&
        [ "$current_hash" = "${restore_installed_hashes[$index]}" ]; then
        action="remove"
      else
        die "refusing to overwrite a file changed after installation: $rel (sha256 $current_hash)"
      fi
      restore_current_existed+=("1")
      restore_current_hashes+=("$current_hash")
    else
      if [ "$state" = "existing" ]; then action="restore"; else action="skip"; fi
      restore_current_existed+=("0")
      restore_current_hashes+=("-")
    fi
    restore_actions+=("$action")
    [ "$action" = "skip" ] || any_changes=1
  done

  if [ "$any_changes" -eq 0 ]; then
    echo "backup is already restored: $backup"
    return
  fi

  collect_restore_parents "$game"
  stage_dir="$(mktemp -d "$game/.dr-tas-chs-restore.XXXXXX")"
  for index in "${!restore_rels[@]}"; do
    [ "${restore_actions[$index]}" != "skip" ] || continue
    rel="${restore_rels[$index]}"
    if [ "${restore_current_existed[$index]}" = "1" ]; then
      mkdir -p -- "$stage_dir/current/$(relative_parent "$rel")"
      [ "$(hash_file "$game/$rel")" = "${restore_current_hashes[$index]}" ] ||
        die "current file changed while staging restore: $rel"
      cp -a -- "$game/$rel" "$stage_dir/current/$rel"
      [ "$(hash_file "$stage_dir/current/$rel")" = "${restore_current_hashes[$index]}" ] ||
        die "could not snapshot current file before restore: $rel"
    fi
    if [ "${restore_actions[$index]}" = "restore" ]; then
      mkdir -p -- "$stage_dir/original/$(relative_parent "$rel")"
      source_path_is_safe "$backup/files" "$rel" ||
        die "unsafe original file in backup: $rel"
      cp -a -- "$backup/files/$rel" "$stage_dir/original/$rel"
      [ "$(hash_file "$stage_dir/original/$rel")" = "${restore_original_hashes[$index]}" ] ||
        die "could not stage original file: $rel"
    fi
  done

  writes_started=1
  for rel in "${restore_created_dirs[@]}"; do
    destination_parent_is_safe "$game" "$rel" ||
      die "unsafe destination parent during restore: $game/$rel"
    [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ] ||
      die "destination changed during restore: $game/$rel"
    index="${#restore_made_dirs[@]}"
    restore_made_dirs+=("$rel")
    if ! mkdir -- "$game/$rel"; then
      unset 'restore_made_dirs[index]'
      die "could not create restore directory: $game/$rel"
    fi
  done
  for index in "${!restore_rels[@]}"; do
    rel="${restore_rels[$index]}"
    [ "${restore_actions[$index]}" != "skip" ] || continue
    destination_parent_is_safe "$game" "$rel" ||
      die "unsafe destination parent during restore: $game/$rel"
    if [ "${restore_current_existed[$index]}" = "1" ]; then
      [ -f "$game/$rel" ] && [ ! -L "$game/$rel" ] &&
        [ "$(hash_file "$game/$rel")" = "${restore_current_hashes[$index]}" ] ||
        die "destination changed during restore: $game/$rel"
    else
      [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ] ||
        die "destination changed during restore: $game/$rel"
    fi
    case "${restore_actions[$index]}" in
      restore)
        restore_written_indices+=("$index")
        move_staged_file_atomically "$stage_dir/original/$rel" "$game/$rel" ||
          die "could not atomically restore file: $rel"
        [ "$(hash_file "$game/$rel")" = "${restore_original_hashes[$index]}" ] ||
          die "restored file verification failed: $rel"
        ;;
      remove)
        restore_written_indices+=("$index")
        rm -f -- "$game/$rel"
        [ ! -e "$game/$rel" ] && [ ! -L "$game/$rel" ] ||
          die "could not remove installed file: $rel"
        ;;
    esac
  done

  remove_created_dirs "$game" "${restore_original_missing_dirs[@]}"
  writes_started=0
  atomic_write_line "$backup/status" "RESTORED" 2>/dev/null ||
    echo "warning: restored successfully but could not update backup status" >&2
  echo "restored pre-install files in $game"
  echo "backup: $backup"
}

main() {
  local command_name required_command
  local game="${DELTARUNE_GAME_DIR:-}" out="$root/output" backup=""

  if [ "$#" -eq 0 ]; then
    usage
    exit 2
  fi
  case "$1" in
    apply | restore)
      command_name="$1"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      command_name="apply"
      game="$1"
      shift
      ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --game-dir)
        [ "$#" -ge 2 ] || die "--game-dir requires a value"
        game="$2"
        shift 2
        ;;
      --output-dir)
        [ "$command_name" = "apply" ] || die "--output-dir is only valid with apply"
        [ "$#" -ge 2 ] || die "--output-dir requires a value"
        out="$2"
        shift 2
        ;;
      --backup)
        [ "$command_name" = "restore" ] || die "--backup is only valid with restore"
        [ "$#" -ge 2 ] || die "--backup requires a value"
        backup="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  [ -n "$game" ] || { usage; exit 2; }
  [ "$game" != *$'\n'* ] || die "game directory may not contain a newline"
  game="$(canonical_dir "$game")"
  require_commands
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"
  load_version_manifest

  if [ "$command_name" = "apply" ]; then
    for required_command in ffprobe fpcalc gawk awk cmp; do
      command -v "$required_command" >/dev/null 2>&1 ||
        die "required command not found: $required_command"
    done
    out="$(canonical_dir "$out")"
    ! paths_overlap "$out" "$game" ||
      die "output directory and game directory must be disjoint"
    apply_output "$game" "$out"
  else
    if [ -z "$backup" ]; then
      [ -f "$root/latest_backup.txt" ] || die "no latest backup; pass --backup DIR"
      backup="$(<"$root/latest_backup.txt")"
    fi
    backup="$(canonical_dir "$backup")"
    ! paths_overlap "$backup" "$game" ||
      die "backup directory and game directory must be disjoint"
    restore_backup "$game" "$backup"
  fi
}

main "$@"
