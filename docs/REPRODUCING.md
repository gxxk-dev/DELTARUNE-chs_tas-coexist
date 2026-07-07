# Reproducing the Research Build

这份说明记录研究复现路线。仓库不包含游戏资产、Mod patches、CHS release data 或最终 `data.win`。

## High-level process

1. 从正版 DELTARUNE 读取原始 `data.win` files。
2. 使用 Keucher/TAS Mod 的 `.bps` patches 生成 TAS baseline。
3. 使用 DeltaruneChinese packer，以 TAS baseline 作为输入导入 CHS resources。
4. 对冲突 GML 保留 Keucher/TAS runtime hooks，并应用本仓库记录的 Keucher savestate/pause hotfix。
5. 将合并后的 chapter `data.win` 同时安装为 `data_keucher.win`，因为 Keucher chapter select 会加载这个文件。

## Important merge notes

已确认的关键点：

- 直接把 CHS `.xdelta` 应用于 Keucher/TAS `data.win` 会因为 xdelta checksum 不匹配失败。
- Chapter 1-5 的 `gml_Object_obj_initializer2_Create_0` 必须保留 Keucher/TAS 的 savestate guard：

```gml
if (obj_savestate_manager.loading)
{
    exit;
}
```

- Chapter 1-5 的 `gml_Object_obj_initializer2_Create_0` 必须调用：

```gml
mod_init();
```

缺少 `mod_init();` 会导致进入章节时 `obj_time` 读取未初始化的 `global.debug_keybinds_on` 并崩溃。

- Chapter 5 的 `gml_Object_obj_town_event_Create_0` 也需要保留 savestate loading guard。
- Chapter 1-5 需要应用 `scripts/apply_keucher_savestate_hotfix.sh`：

```bash
./scripts/apply_keucher_savestate_hotfix.sh work/DeltaruneChinese-260707/workspace build/keucher
```

这个 hotfix 会导入两处 Keucher code 修正：

- `gml_Object_obj_savestate_manager_Create_0`：保留 Keucher 原始 savestate manager，但在 `decode_var_info()` 还原 constructor 时先把 JSON 里的 numeric script asset id 转成 callable method，再调用 `new`。否则读取包含 constructor struct 的 savestate 会在 `obj_savestate_manager` Alarm 0 报 `Trying to construct something that isn't a function`。
- `gml_Object_obj_readable_room1_Step_0`：在 `obj_savestate_manager.loading` 期间直接 `exit`，并兜底初始化缺失的 `myinteract`。否则从非对话场景读取一个保存于对话中的 savestate 时，目标房间实例可能在 Alarm 0 写回保存变量前先跑 Step，并报 `Variable obj_readable_room1.myinteract not set before reading it`。

- Chapter 5 需要应用 `scripts/apply_ch5_pause_savestate_hotfix.sh`：

```bash
./scripts/apply_ch5_pause_savestate_hotfix.sh output/chapter5_windows/data.win
```

这个 hotfix 会让 `gml_GlobalScript_mod_init` 创建并持久化 `obj_savestate_manager`，同时给 `obj_pause_emulator_Create_0`、`obj_time_Create_0` 和 `obj_time_Step_1` 的 `obj_savestate_manager.loading` 读取加上存在性检查。否则某些 boss 战房间 Pause 时会报 `Unable to find any instance for object index '1742' name 'obj_savestate_manager'`。

- 每个 `chapterN_windows/data_keucher.win` 应与对应的 merged `chapterN_windows/data.win` byte-for-byte 一致。

## Expected final output hashes

当前成功构建的 final output SHA256：

| File | SHA256 |
| --- | --- |
| `output/data.win` | `1431831521882ba858811a3ed8112d9d06fdbfa189ace407c5ec95082ea7c954` |
| `output/chapter1_windows/data.win` | `138023d7d1c4eeedc76487097cbb204c085a727f3b91eac5c91078a0bbf98ff9` |
| `output/chapter2_windows/data.win` | `4b33fe4c66179b4f9ec73ccb9b31861f71550bc8470e93835cd5a6917102a2c4` |
| `output/chapter3_windows/data.win` | `52319d6f0060102cec73eeaf27c543422a634401ece4f8b9facf9e9a50de27b7` |
| `output/chapter4_windows/data.win` | `5de41b573d58a6e3042daee01e818de5baeba3de39cea8d2b6f7334f2f2ec3bc` |
| `output/chapter5_windows/data.win` | `c4ebafae714e4a93eed62bda7e79739b10ed8f7e8d15ea235691157fd4835364` |

## Verification

Compact verification records are in:

- `verify/final_audit.txt`
- `verify/code_conflicts_fast_after/*.tsv`
- `verify/code_lists/*.txt`

Run local asset checks:

```bash
./scripts/verify_local_assets.sh
```

Run code conflict scan after rebuilding local `work/` and `build/` directories:

```bash
./scripts/check_code_conflicts.sh
```

## Installing local output

After recreating `output/`, install with:

```bash
./install_output.sh "$DELTARUNE_GAME_DIR"
```

The script creates a timestamped local backup in `backups/` before copying files.
