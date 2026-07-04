#!/usr/bin/env bash
set -euo pipefail

fail=0

check_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "missing: $path" >&2
    fail=1
    return
  fi
  echo "ok: $path"
}

check_sha256() {
  local expected="$1"
  local path="$2"
  check_file "$path"
  [ -f "$path" ] || return

  local actual
  actual="$(sha256sum "$path" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    echo "sha256 mismatch: $path" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    fail=1
    return
  fi
  echo "sha256 ok: $path"
}

game="${DELTARUNE_GAME_DIR:-}"
keucher="${KEUCHER_MOD_DIR:-}"
chs="${CHS_RELEASE_DIR:-}"
chs_source="${DELTARUNE_CHINESE_DIR:-}"

if [ -z "$game" ]; then
  echo "DELTARUNE_GAME_DIR is not set" >&2
  fail=1
else
  check_file "$game/data.win"
  for c in 1 2 3 4 5; do
    check_file "$game/chapter${c}_windows/data.win"
  done
fi

if [ -z "$keucher" ]; then
  echo "KEUCHER_MOD_DIR is not set" >&2
  fail=1
else
  check_sha256 328f7ba64ac3b85e62383015f00930d4d5a0ff8d5a5b7fa3deb64249f4891590 "$keucher/patch_files/ch5_latest-chapter_select.bps"
  check_sha256 3840d43c0615ebf4ea124c3eab42251ff52f4553eaed49c2a9a2d2504ce249a3 "$keucher/patch_files/ch5_latest-chapter1.bps"
  check_sha256 7a8f7e1e4faf0a28373ca8d6ed91aae1f1310d341af3f983560840cb5e315657 "$keucher/patch_files/ch5_latest-chapter2.bps"
  check_sha256 7225ddc3b5322da2c86d60ff4c64f0d42b0d5ae08af81caf98f640dde0f2f075 "$keucher/patch_files/ch5_latest-chapter3.bps"
  check_sha256 8d7214d79e6f4d59424092c7076614b132cffaf22fb452919dcd393be94a866d "$keucher/patch_files/ch5_latest-chapter4.bps"
  check_sha256 310ee1028c609d854d8816187cfad4e0c16b79b44b55d964e807465c947d218e "$keucher/patch_files/ch5_latest-chapter5.bps"
fi

if [ -z "$chs" ]; then
  echo "CHS_RELEASE_DIR is not set" >&2
  fail=1
else
  check_sha256 2e9d26760203b92cb67fa99d6e28300d02664976e29a9e45fca098e8ef9b9461 "$chs/main.xdelta"
  check_sha256 2e1083219227b371938012a36c776a5790ced8fa403b45b02094eb9c7c1396a9 "$chs/chapter1.xdelta"
  check_sha256 a98580c4febbcae62d4fac457fa53178a37c01145dc37aa0efe58ede0bd2b392 "$chs/chapter2.xdelta"
  check_sha256 620c3239156a38f9559b0fc5c86ffccb25be192a43352e33b57f27ee0e17ef01 "$chs/chapter3.xdelta"
  check_sha256 4563d9b6765fbc790e2367765b3b4dca7b3da2da2c1e27cecd6929f2684529bf "$chs/chapter4.xdelta"
  check_sha256 15627d6912ac2226dab8ff7fac14c3442013f5abbb504262ec955b6203ca92d4 "$chs/chapter5.xdelta"
fi

if [ -z "$chs_source" ]; then
  echo "DELTARUNE_CHINESE_DIR is not set" >&2
  fail=1
else
  check_file "$chs_source/src/deltarunePacker.csproj"
  if git -C "$chs_source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    actual_commit="$(git -C "$chs_source" rev-parse HEAD)"
    expected_commit="5f95b0d1d16f80c267eefb6a9ccfd039b0800e0c"
    if [ "$actual_commit" != "$expected_commit" ]; then
      echo "DeltaruneChinese commit mismatch:" >&2
      echo "  expected: $expected_commit" >&2
      echo "  actual:   $actual_commit" >&2
      fail=1
    else
      echo "DeltaruneChinese commit ok: $actual_commit"
    fi
  else
    echo "warning: DELTARUNE_CHINESE_DIR is not a git checkout; commit cannot be verified" >&2
  fi
fi

exit "$fail"
