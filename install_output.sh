#!/usr/bin/env bash
set -euo pipefail

game="${1:-${DELTARUNE_GAME_DIR:-}}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$root/output"

if [ -z "$game" ]; then
  echo "Usage: install_output.sh <DELTARUNE game dir>" >&2
  echo "Or set DELTARUNE_GAME_DIR." >&2
  exit 2
fi

if [ ! -f "$out/data.win" ]; then
  echo "missing output: $out/data.win" >&2
  exit 1
fi

backup="$root/backups/DELTARUNE-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup"

cp "$game/data.win" "$backup/data.win"
for d in mus vid; do
  [ -d "$game/$d" ] &&
    cp -a "$game/$d" "$backup/$d"
done
for c in 1 2 3 4 5; do
  mkdir -p "$backup/chapter${c}_windows"
  cp "$game/chapter${c}_windows/data.win" "$backup/chapter${c}_windows/data.win"
  [ -f "$game/chapter${c}_windows/data_keucher.win" ] &&
    cp "$game/chapter${c}_windows/data_keucher.win" "$backup/chapter${c}_windows/data_keucher.win"
  [ -d "$game/chapter${c}_windows/lang" ] &&
    cp -a "$game/chapter${c}_windows/lang" "$backup/chapter${c}_windows/lang"
  [ -d "$game/chapter${c}_windows/mus" ] &&
    cp -a "$game/chapter${c}_windows/mus" "$backup/chapter${c}_windows/mus"
  [ -d "$game/chapter${c}_windows/vid" ] &&
    cp -a "$game/chapter${c}_windows/vid" "$backup/chapter${c}_windows/vid"
done

cp "$out/data.win" "$game/data.win"
for d in mus vid; do
  [ -d "$out/$d" ] &&
    cp -a "$out/$d" "$game/"
done
for c in 1 2 3 4 5; do
  cp "$out/chapter${c}_windows/data.win" "$game/chapter${c}_windows/data.win"
  cp "$out/chapter${c}_windows/data.win" "$game/chapter${c}_windows/data_keucher.win"
  [ -d "$out/chapter${c}_windows/lang" ] &&
    cp -a "$out/chapter${c}_windows/lang" "$game/chapter${c}_windows/"
  [ -d "$out/chapter${c}_windows/mus" ] &&
    cp -a "$out/chapter${c}_windows/mus" "$game/chapter${c}_windows/"
  [ -d "$out/chapter${c}_windows/vid" ] &&
    cp -a "$out/chapter${c}_windows/vid" "$game/chapter${c}_windows/"
done

echo "$backup" > "$root/latest_backup.txt"
echo "installed TAS+CHS output to $game"
echo "backup: $backup"
