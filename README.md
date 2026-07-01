# DELTARUNE TAS + CHS Coexist Research

这个仓库记录让 Keucher Mod 和 DeltaruneChinese CHS Mod 在 DELTARUNE full game 中共存的研究过程。

仓库不发布 DELTARUNE、Keucher Mod、CHS patch、生成后的 `data.win`、`lang/` 或 `vid/` assets。复现者需要自己准备正版游戏和第三方 Mod/patch 文件。

## 安装器（dr-tas-chs）

`tools/patcher/` 是一个**自带补丁数据、跨平台**的安装器（Rust + egui）：把研究得到的合并结果以内嵌 xdelta 差分的形式，一键应用到玩家自有的**纯净正版 DELTARUNE**。同一个二进制无参数启动图形界面，也提供 `apply`/`verify`/`restore` 命令行子命令，含 SHA256 预检、结果校验、时间戳备份与一键还原。

内嵌数据（补丁、`lang/`、`vid/`、中文字体）派生自第三方且体积大，**不入库**（`.gitignore` 忽略 `tools/patcher/assets/`）；构建前用 `scripts/gen_assets.sh` 从 vanilla 与 `output/` 生成。用法与发布见 [`tools/patcher/README.md`](tools/patcher/README.md)、第三方授权见 [`tools/patcher/THIRD_PARTY.md`](tools/patcher/THIRD_PARTY.md)。


## What is tracked

- 研究结论和复现说明。
- 本地辅助脚本，例如 `scripts/apply_bps.js`、`scripts/check_code_conflicts.sh`。
- 小型 `data.win` inspection tool：`tools/DataWinProbe/`。
- 跨平台 GUI/CLI 安装器源码：`tools/patcher/`（自带 xdelta 补丁，一键应用到纯净 DELTARUNE；内嵌数据不入库，见下）。
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
- Keucher Mod `v5.10.5` PC `.bps` patches。
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
