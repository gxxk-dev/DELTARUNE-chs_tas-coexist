#!/usr/bin/env bash
# 从 vanilla DELTARUNE + 合并结果 output/ 生成 patcher 内嵌资源:
#   - 6 个 xdelta 差分(main + chapter1-5 的 data.win,vanilla -> merged)
#   - 各章 CHS lang/ JSON、ch3/ch5 vid/ mp4 与 Ch5 intro 音频
#   - manifest.json(记录每个目标的相对路径、vanilla 源 sha256、结果 sha256)
#
# 这些产物是第三方(Keucher Mod + DeltaruneChinese/CHS)派生内容,默认被 .gitignore
# 忽略,只随 Release 二进制分发,不提交进公开仓库。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
game="${DELTARUNE_GAME_DIR:?set DELTARUNE_GAME_DIR to a clean vanilla DELTARUNE install}"
out="${OUTPUT_DIR:-$root/output}"
assets="${ASSETS_DIR:-$root/tools/patcher/assets}"

# xdelta3 源窗口:必须 >= 最大源文件(ch5 约 165MiB),否则压缩效果差。256MiB 够用。
srcwin="${XDELTA_SRCWIN:-268435456}"

command -v xdelta3 >/dev/null || { echo "xdelta3 not found on PATH" >&2; exit 2; }
command -v zstd >/dev/null || { echo "zstd not found on PATH" >&2; exit 2; }

sha() { sha256sum "$1" | awk '{print $1}'; }
sz()  { wc -c < "$1" | tr -d ' '; }

# id  rel_path  needs_data_keucher_win
targets=(
  "main:data.win:0"
  "ch1:chapter1_windows/data.win:1"
  "ch2:chapter2_windows/data.win:1"
  "ch3:chapter3_windows/data.win:1"
  "ch4:chapter4_windows/data.win:1"
  "ch5:chapter5_windows/data.win:1"
)

rm -rf "$assets"
mkdir -p "$assets/patches" "$assets/lang" "$assets/vid" "$assets/fonts"

# GUI 用的中文字体(HarmonyOS Sans SC)。子集化到 GB2312 + 源码用字,~8M -> ~2M。可用 UI_FONT 覆盖来源。
ui_font="${UI_FONT:-/home/frez79/下载/HarmonyOS-Sans/HarmonyOS Sans/HarmonyOS_Sans_SC/HarmonyOS_Sans_SC_Regular.ttf}"
if [ -f "$ui_font" ]; then
  pybin="$(command -v python3 || true)"
  if [ -n "$pybin" ] && ! "$pybin" -c "import fontTools" 2>/dev/null; then
    venv="${FONT_VENV:-/tmp/drtcs-ftenv}"
    if python3 -m venv "$venv" >/dev/null 2>&1 && "$venv/bin/pip" install --quiet fonttools >/dev/null 2>&1; then
      pybin="$venv/bin/python"
    fi
  fi
  if [ -n "$pybin" ] && "$pybin" -c "import fontTools" 2>/dev/null; then
    "$pybin" "$root/scripts/subset_font.py" "$ui_font" "$assets/fonts/ui.ttf" "$root/tools/patcher/src"
    echo ">> ui font subset -> fonts/ui.ttf ($(du -h "$assets/fonts/ui.ttf" | cut -f1))"
  else
    cp -f "$ui_font" "$assets/fonts/ui.ttf"
    echo "!! fonttools 不可用,已内嵌完整字体(体积较大);装 fonttools 可自动子集化" >&2
  fi
else
  echo "!! UI_FONT not found: $ui_font (GUI 中文会缺字;设置 UI_FONT 指向一个中文 ttf)" >&2
fi

target_json=""
for entry in "${targets[@]}"; do
  IFS=':' read -r id rel keucher <<<"$entry"
  src="$game/$rel"
  dst="$out/$rel"
  [ -f "$src" ] || { echo "missing vanilla source: $src" >&2; exit 1; }
  [ -f "$dst" ] || { echo "missing merged target: $dst" >&2; exit 1; }

  patch="$assets/patches/$id.xdelta"
  echo ">> encoding $id: $rel"
  xdelta3 -e -9 -S djw -B "$srcwin" -f -s "$src" "$dst" "$patch"

  src_sha="$(sha "$src")"; dst_sha="$(sha "$dst")"; psz="$(sz "$patch")"
  echo "   src=$src_sha dst=$dst_sha patch=${psz}B"

  # 采样自校验:立即用 xdelta3 -d 还原并比对结果哈希,确保补丁正确
  tmp="$(mktemp)"
  xdelta3 -d -f -s "$src" "$patch" "$tmp"
  [ "$(sha "$tmp")" = "$dst_sha" ] || { echo "   PATCH VERIFY FAILED for $id" >&2; rm -f "$tmp"; exit 1; }
  rm -f "$tmp"
  echo "   patch verify ok"

  target_json+="    {\"id\":\"$id\",\"rel\":\"$rel\",\"patch\":\"patches/$id.xdelta\",\"src_sha256\":\"$src_sha\",\"dst_sha256\":\"$dst_sha\",\"patch_bytes\":$psz,\"data_keucher_win\":$([ "$keucher" = 1 ] && echo true || echo false)},
"
done
target_json="${target_json%,
}"

# 收集 CHS 外置资源(lang/ 各章,vid/ 仅 ch3/ch5),生成 extras 映射
extra_json=""

# ch5 intro 在 GML 里使用相对路径加载。不同启动方式下 working_directory
# 可能落在游戏根目录或 chapter5_windows,因此同时铺放 root 与 chapter fallback。
intro_audio="$out/mus/ch5_intro_audio.ogg"
if [ -f "$intro_audio" ]; then
  mkdir -p "$assets/mus/chapter5"
  zstd -19 -q -f -o "$assets/mus/chapter5/ch5_intro_audio.ogg.zst" "$intro_audio"
  extra_json+="    {\"asset\":\"mus/chapter5/ch5_intro_audio.ogg\",\"rel\":\"mus/ch5_intro_audio.ogg\"},
"
  extra_json+="    {\"asset\":\"mus/chapter5/ch5_intro_audio.ogg\",\"rel\":\"chapter5_windows/mus/ch5_intro_audio.ogg\"},
"
fi

for c in 1 2 3 4 5; do
  langdir="$out/chapter${c}_windows/lang"
  if [ -d "$langdir" ]; then
    mkdir -p "$assets/lang/chapter${c}"
    for f in "$langdir"/*; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"
      # 文本压缩率极高(~20x),内嵌 .zst,运行时解压后铺放。manifest 里仍用逻辑名。
      zstd -19 -q -f -o "$assets/lang/chapter${c}/$bn.zst" "$f"
      extra_json+="    {\"asset\":\"lang/chapter${c}/$bn\",\"rel\":\"chapter${c}_windows/lang/$bn\"},
"
    done
  fi
  viddir="$out/chapter${c}_windows/vid"
  if [ -d "$viddir" ]; then
    mkdir -p "$assets/vid/chapter${c}"
    for f in "$viddir"/*; do
      [ -e "$f" ] || continue
      bn="$(basename "$f")"
      # mp4 已压缩,zstd 只再挤出约 1.5x,但省几 MB;运行时解压铺放。
      zstd -19 -q -f -o "$assets/vid/chapter${c}/$bn.zst" "$f"
      extra_json+="    {\"asset\":\"vid/chapter${c}/$bn\",\"rel\":\"chapter${c}_windows/vid/$bn\"},
"
      if [ "$c" = 5 ] && [[ "$bn" == ch5_intro_*.mp4 ]]; then
        extra_json+="    {\"asset\":\"vid/chapter${c}/$bn\",\"rel\":\"vid/$bn\"},
"
      fi
    done
  fi
done
extra_json="${extra_json%,
}"

cat > "$assets/manifest.json" <<EOF
{
  "schema": 1,
  "description": "DELTARUNE Keucher Mod + CHS coexist patch set. Third-party derived content; apply only to a matching clean vanilla install.",
  "keucher_mod_version": "v5.10.7",
  "keucher_mod_commit": "f3437becd845f34ce9cabe2709fb36e7e549a8be",
  "deltarune_chinese_commit": "824524b6c86b4b902ba13ee6c5483f3cfeef3cec",
  "targets": [
$target_json
  ],
  "extras": [
$extra_json
  ]
}
EOF

echo
echo "assets written to $assets"
echo "total patches size: $(du -sh "$assets/patches" | awk '{print $1}')"
echo "total assets  size: $(du -sh "$assets" | awk '{print $1}')"
