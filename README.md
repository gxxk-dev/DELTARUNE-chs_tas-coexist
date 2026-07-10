# DELTARUNE TAS + CHS Coexist Research

这个仓库记录让 Keucher Mod 和 DeltaruneChinese CHS Mod 在 DELTARUNE full game 中共存的研究过程。

仓库不发布 DELTARUNE、Keucher Mod、CHS patch、生成后的 `data.win`、`lang/` 或 `vid/` assets。复现者需要自己准备正版游戏和第三方 Mod/patch 文件。

## 安装器（dr-tas-chs）

`tools/patcher/` 是一个**自带补丁数据、跨平台**的安装器（Rust + egui）：把研究得到的合并结果以内嵌 xdelta 差分的形式，一键应用到玩家自有的**纯净正版 DELTARUNE**。同一个二进制无参数启动图形界面，也提供 `apply`/`verify`/`restore` 命令行子命令，含 SHA256 预检、结果校验、时间戳备份与一键还原。

内嵌数据（补丁、`lang/`、`vid/`、`mus/`、中文字体）派生自第三方且体积大，**不入库**（`.gitignore` 忽略 `tools/patcher/assets/`）；构建前用 `scripts/gen_assets.sh` 从 vanilla 与 `output/` 生成。用法与发布见 [`tools/patcher/README.md`](tools/patcher/README.md)、第三方授权见 [`tools/patcher/THIRD_PARTY.md`](tools/patcher/THIRD_PARTY.md)。


## What is tracked

- 研究结论和复现说明。
- 本地辅助脚本，例如 `scripts/apply_bps.js`、`scripts/check_code_conflicts.sh`。
- 小型 `data.win` inspection tool：`tools/DataWinProbe/`。
- 跨平台 GUI/CLI 安装器源码：`tools/patcher/`（自带 xdelta 补丁，一键应用到纯净 DELTARUNE；内嵌数据不入库，见下）。
- Compact verification records：`verify/final_audit.txt`、`verify/code_lists_v5.10.7/*.txt`、`verify/code_conflicts_v5.10.7/*.tsv`。
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
- Keucher Mod `v5.10.7` PC `.bps` patches（2026-07-09 重新发布的资产）。
- DELTARUNE Chapter 5 `v0.0.247` data files。
- DeltaruneChinese source commit `824524b6c86b4b902ba13ee6c5483f3cfeef3cec`。
- CHS release package，包含 `.xdelta`、`lang/`、`vid/` 和 Ch5 intro assets。
- RomPatcher.js，用于应用 `.bps` patches。

## Reproducing

见 [docs/REPRODUCING.md](docs/REPRODUCING.md)。

本地资产校验：

```bash
export DELTARUNE_GAME_DIR="/path/to/DELTARUNE"
export KEUCHER_MOD_DIR="/path/to/Keucher.Mod.v5.10.7"
export CHS_RELEASE_DIR="/path/to/dr-ch-patch"
export DELTARUNE_CHINESE_DIR="/path/to/DeltaruneChinese"

./scripts/verify_local_assets.sh
```

## Key findings

- 直接把 CHS `.xdelta` 应用于 Keucher/TAS `data.win` 会因为 checksum mismatch 失败。
- 可行路线是先用 Keucher `.bps` 生成 TAS baseline，再用 DeltaruneChinese packer 导入 CHS resources。
- Chapter 1-5 的 `gml_Object_obj_initializer2_Create_0` 必须保留 Keucher/TAS 的 savestate guard 和 `mod_init();`。
- 缺少 `mod_init();` 会导致进入章节时 `global.debug_keybinds_on` 未初始化。
- Keucher `v5.10.7` 使用 Savestates v2.1；必须移除旧版 manager 全量导入，并在 CHS 完整替换代码后运行 `scripts/reinstrument_keucher_savestate_v2.sh`，恢复 logged calls 与 loading guards。
- Chapter 1-5 需要应用 `scripts/apply_keucher_savestate_hotfix.sh`，保留 initializer hooks，并让 `obj_readable_room1` 的 Step 在 savestate loading 期间跳过。
- Chapter 5 需要应用 `scripts/apply_ch5_v0247_compat.sh`，保留 DELTARUNE `v0.0.247` 的 credits、悬崖对话、版本号与 Terracota 计时修复。
- Chapter 5 需要应用 `scripts/apply_ch5_pause_savestate_hotfix.sh`，让 `obj_savestate_manager` 成为 Keucher 常驻实例，并修复 Pause/`obj_time` 在 boss 战房间里直接读取缺失 manager 的崩溃。
- Keucher chapter select 会加载 `data_keucher.win`，所以每个 chapter 的 `data_keucher.win` 必须与 merged chapter `data.win` 一致。

## Verification

`verify/final_audit.txt` 记录了当前本地输出哈希、外置资源、核心代码检查和代码冲突扫描：

- 六个 merged `data.win` 的 SHA256 与记录一致。
- Savestates v2.1、Ch5 `v0.0.247` 兼容修复和 Flowery boss practice 修复均存在。
- Chapter 1-5 的 CHS language JSON 与需要的视频、音频资源齐全。
- 175 个 CHS import 目标的 code conflict scan 没有 `merged_lost_keucher` 条目。
- 验证过程不写入真实游戏目录；安装时由安装器生成 `data_keucher.win` 并创建备份。

## Before publishing

运行：

```bash
./scripts/check_publish_tree.sh
```

这个检查会阻止常见误提交：`data.win`、`.bps`、`.xdelta`、视频、第三方 worktree、backup、generated output、大文件和反编译 GML dumps。
