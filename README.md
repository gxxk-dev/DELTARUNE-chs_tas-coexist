# DELTARUNE TAS + CHS Coexist Research

这个仓库记录让 Keucher/TAS Mod 和 DeltaruneChinese CHS Mod 在 DELTARUNE full game 中共存的研究过程。

仓库不发布 DELTARUNE、Keucher/TAS Mod、CHS patch、生成后的 `data.win`、`lang/` 或 `vid/` assets。复现者需要自己准备正版游戏和第三方 Mod/patch 文件。

## What is tracked

- 研究结论和复现说明。
- 本地辅助脚本，例如 `scripts/apply_bps.js`、`scripts/check_code_conflicts.sh`。
- 小型 `data.win` inspection tool：`tools/DataWinProbe/`。
- Compact verification records：`verify/final_audit.txt`、`verify/code_lists/*.txt`、`verify/code_conflicts_fast_after/*.tsv`。
- Third-party asset manifest：`third_party_manifest.yml`。

## What is not tracked

`.gitignore` 默认排除：

- `build/`
- `output/`
- `backups/`
- `work/`
- `latest_backup.txt`
- `*.win`、`*.bps`、`*.xdelta`、`*.mp4` 等 binary assets

这些文件对本地复现有用，但不适合公开再分发。

## Dependencies

见 [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)。

核心依赖：

- 正版 DELTARUNE full game installation。
- Keucher/TAS Mod `v5.10.5` PC `.bps` patches。
- DeltaruneChinese source commit `a43a1ec74d2af9a63d6fddc97b8fef708a1a941f`。
- CHS release package，包含 `.xdelta`、`lang/` 和 `vid/` files。
- RomPatcher.js，用于应用 `.bps` patches。

## Reproducing

见 [docs/REPRODUCING.md](docs/REPRODUCING.md)。

本地资产校验：

```bash
export DELTARUNE_GAME_DIR="/path/to/DELTARUNE"
export KEUCHER_MOD_DIR="/path/to/Keucher.Mod.v5.10.5"
export CHS_RELEASE_DIR="/path/to/dr-ch-patch"
export DELTARUNE_CHINESE_DIR="/path/to/DeltaruneChinese"

./scripts/verify_local_assets.sh
```

## Key findings

- 直接把 CHS `.xdelta` 应用于 Keucher/TAS `data.win` 会因为 checksum mismatch 失败。
- 可行路线是先用 Keucher `.bps` 生成 TAS baseline，再用 DeltaruneChinese packer 导入 CHS resources。
- Chapter 1-5 的 `gml_Object_obj_initializer2_Create_0` 必须保留 Keucher/TAS 的 savestate guard 和 `mod_init();`。
- 缺少 `mod_init();` 会导致进入章节时 `global.debug_keybinds_on` 未初始化。
- Keucher chapter select 会加载 `data_keucher.win`，所以每个 chapter 的 `data_keucher.win` 必须与 merged chapter `data.win` 一致。

## Verification

`verify/final_audit.txt` 记录了最终本地安装验证：

- Installed `data.win` files 与 `output/` byte-for-byte 一致。
- 每个 chapter 的 `data_keucher.win` 与 merged chapter `data.win` 一致。
- Keucher strings 存在，包括 `data_keucher.win`、`Keucher Mod`、`obj_savestate_manager` 和 `Welcome to Keucher Mod!`。
- CHS language JSON 包含中文文本。
- Code conflict scan 没有 `merged_lost_keucher` 条目。

## Before publishing

运行：

```bash
./scripts/check_publish_tree.sh
```

这个检查会阻止常见误提交：`data.win`、`.bps`、`.xdelta`、视频、第三方 worktree、backup、generated output、大文件和反编译 GML dumps。
