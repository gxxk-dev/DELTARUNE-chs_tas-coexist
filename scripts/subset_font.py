#!/usr/bin/env python3
# 将中文 UI 字体子集化,只保留 GB2312 常用汉字 + 源码里实际出现的字符 + 常用符号,
# 从整套 CJK(约 8MB)缩到 ~2MB。GUI 只渲染安装器自身文案与用户路径,不需要全字库。
#
# 用法: python subset_font.py <源字体.ttf> <输出.ttf> <rs源码目录>
# 需要 fontTools(pyftsubset)。由 scripts/gen_assets.sh 用带 fonttools 的 python 调用。
import sys
import glob
import os


def gb2312_chars() -> set:
    """枚举 GB2312 可解码的全部汉字/符号(~7400 字),覆盖绝大多数真实中文路径与文本。"""
    out = set()
    for i in range(0xA1, 0xFF):
        for j in range(0xA1, 0xFF):
            try:
                out.add(bytes([i, j]).decode("gb2312"))
            except Exception:
                pass
    return out


def source_chars(src_dir: str) -> set:
    """收集 rs 源码中出现的所有字符(确保 UI 里写死的中文一定在子集内)。"""
    out = set()
    for p in glob.glob(os.path.join(src_dir, "*.rs")):
        with open(p, encoding="utf-8") as f:
            out |= set(f.read())
    return out


def main() -> None:
    src_font, out_font, src_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    chars = gb2312_chars() | source_chars(src_dir)
    chars = {c for c in chars if ord(c) >= 0x20}  # 去控制字符

    os.makedirs(os.path.dirname(out_font) or ".", exist_ok=True)
    text_file = out_font + ".chars.txt"
    with open(text_file, "w", encoding="utf-8") as f:
        f.write("".join(sorted(chars)))

    from fontTools.subset import main as pyftsubset

    pyftsubset([
        src_font,
        "--text-file=" + text_file,
        # 兜底:基本拉丁、常用标点、CJK 标点、全角/半角
        "--unicodes=U+0020-00FF,U+2000-206F,U+3000-303F,U+FF00-FFEF",
        "--output-file=" + out_font,
        "--no-hinting",
        "--drop-tables+=DSIG",
        "--name-IDs=",
        "--notdef-outline",
        "--recalc-timestamp=0",
    ])
    os.remove(text_file)
    print(f">> subset {os.path.getsize(out_font) // 1024} KiB -> {out_font}")


if __name__ == "__main__":
    main()
