# Reproducing the Research Build

这份说明记录 Keucher Mod `v5.10.7`、DeltaruneChinese `824524b` 与 DELTARUNE Chapter 5 `v0.0.247` 的共存构建路线。仓库不包含游戏资产、第三方补丁或最终 `data.win`。

## High-level process

1. 从正版 DELTARUNE `v0.0.247` 读取原始 `data.win` files。
2. 应用 Keucher Mod `v5.10.7` PC `.bps`，生成 main 与 Chapter 1-5 baseline。
3. 把 baseline 放入 DeltaruneChinese workspace，并运行 `scripts/apply_keucher_savestate_hotfix.sh`：移除会把 Savestates v2.1 降回 v1 的旧 manager import，同时保留 initializer、town event 与 readable-room hooks。
4. 运行 `scripts/apply_ch5_v0247_compat.sh`，把 DELTARUNE Ch5 `v0.0.247` 的 4 组更新合入 CHS imports。
5. 用 DeltaruneChinese packer 导入中文代码、字体、贴图和文本。
6. 对 packer result 运行 `scripts/reinstrument_keucher_savestate_v2.sh`，恢复被 CHS `QueueReplace` 覆盖的 logged calls 与 loading guards。
7. 依次运行 Savestates v2.1 performance、Ch5 pause 和 Ch5 rhythm font hotfix。
8. 将每章最终 `data.win` 同时安装为 `data_keucher.win`。

## Savestates v2.1

`v5.10.7` 把 savestate 实现从 `src/mod/common/_savestates` 移到独立的 `src/savestate`，并由 `BuildSavestate()` 显式注入。旧版 `gml_Object_obj_savestate_manager_Create_0.gml` import 不能继续使用，否则 CHS packer 会把整个 v2 manager 覆盖回 v1。

新版 constructor 以名称保存并通过 `asset_get_index(arg0.const_func)` 恢复，不再应用旧的 `method(undefined, const_func)` 补丁。仍需保留：

- `obj_readable_room1` Step 的 loading guard 与 `myinteract` fallback。
- CHS imports 中 Create/BeginStep/RoomStart/PreCreate 的 loading guard。
- CHS imports 中 audio/DS/sprite/path/JSON/call_later 的 logged wrappers。
- Ch5 boss room 的 persistent manager 与安全存在性检查。

`scripts/apply_savestate_performance_hotfix.sh` 已按 v2 事件职责重写：Create 维护音频/DS/sprite 基线，Alarm 0 修 call_later，Step Begin 保存，Alarm 1 读取与清理。

## Chapter 5 v0.0.247

官方 `v5.10.7` Release 资产在 2026-07-09 重新生成，目标 Ch5 已是 `v0.0.247`。DeltaruneChinese `824524b` 的部分 imports 仍基于较早版本，因此 `scripts/apply_ch5_v0247_compat.sh` 合并：

- 更新 credits（Concept Art、Platforming VFX、Musical Assistance）。
- 悬崖场景的两处 `interjection = -1`（汉化源已包含，脚本验证）。
- initializer 的 `global.versionno = "v0.0.247"`。
- Terracota 三处 turn timer：`275`、`245`、`365`。

## Commands

```bash
# baseline 已由 v5.10.7 BPS 生成到 build/keucher-v5.10.7
./scripts/apply_keucher_savestate_hotfix.sh \
  work/DeltaruneChinese-keucher-v5.10.7/workspace \
  build/keucher-v5.10.7
./scripts/apply_ch5_v0247_compat.sh \
  work/DeltaruneChinese-keucher-v5.10.7/workspace

# 在 DeltaruneChinese worktree 根运行 packer
dotnet build -c Release src
dotnet src/bin/Release/net10.0/deltarunePacker.dll workspace

./scripts/reinstrument_keucher_savestate_v2.sh \
  work/DeltaruneChinese-keucher-v5.10.7/workspace
./scripts/apply_savestate_performance_hotfix.sh output
./scripts/apply_ch5_pause_savestate_hotfix.sh output/chapter5_windows/data.win
./scripts/apply_ch5_rhythm_evaluation_font_hotfix.sh output/chapter5_windows/data.win
```

## Expected final output hashes

| File | SHA256 |
| --- | --- |
| `output/data.win` | `548d07d75812ae04d218dd342cc06404a30c7fe57d70bbf2e7c54b71d036286f` |
| `output/chapter1_windows/data.win` | `9869fc61101c3cdcd2aad998892fa94c4778827eec63f9a1128d8f01c5206629` |
| `output/chapter2_windows/data.win` | `123372dba8e3a22820b3a14a25fb391cf8ac3b67ba10a79ecb5a708cad6fc0a8` |
| `output/chapter3_windows/data.win` | `ad8cb83f6ea183577e5107fd02b31acf1ff2b566a6e413397a99d5850bc50b9e` |
| `output/chapter4_windows/data.win` | `27682b6460e76c6759b7ac79f24e58eedcfe06c5dc96bb912e1658409b00c6a8` |
| `output/chapter5_windows/data.win` | `476530adcf491ce592d65f9ecba80f500c8ac3994b2ddb494acbf05c2911c470` |

## Verification

```bash
./scripts/verify_local_assets.sh
./scripts/check_code_conflicts.sh
./scripts/verify_merged_output.sh output
```

新版报告保存在 `verify/code_conflicts_v5.10.7/*.tsv` 与 `verify/code_lists_v5.10.7/*.txt`。175 个 CHS import 目标没有 `merged_lost_keucher` 条目。

## Installing local output

```bash
./install_output.sh "$DELTARUNE_GAME_DIR"
```

安装脚本会先在 `backups/` 创建带时间戳的本地备份。
