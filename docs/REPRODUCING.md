# Reproducing the Research Build

这份说明记录研究复现路线。仓库不包含游戏资产、Mod patches、CHS release data 或最终 `data.win`。

## High-level process

1. 从正版 DELTARUNE 读取原始 `data.win` files。
2. 使用 Keucher/TAS Mod 的 `.bps` patches 生成 TAS baseline。
3. 使用 DeltaruneChinese packer，以 TAS baseline 作为输入导入 CHS resources。
4. 对冲突 GML 保留 Keucher/TAS runtime hooks，并应用本仓库记录的 Keucher savestate hotfix。
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
- Chapter 1-5 的 `gml_Object_obj_savestate_manager_Create_0` 需要应用 `scripts/apply_keucher_savestate_hotfix.sh`：

```bash
./scripts/apply_keucher_savestate_hotfix.sh work/DeltaruneChinese-260704/workspace build/keucher
```

这个 hotfix 保留 Keucher 原始 savestate manager，但在 `decode_var_info()` 还原 constructor 时先把 JSON 里的 numeric script asset id 转成 callable method，再调用 `new`。否则读取包含 constructor struct 的 savestate 会在 `obj_savestate_manager` Alarm 0 报 `Trying to construct something that isn't a function`。

- 每个 `chapterN_windows/data_keucher.win` 应与对应的 merged `chapterN_windows/data.win` byte-for-byte 一致。

## Expected final output hashes

当前成功构建的 final output SHA256：

| File | SHA256 |
| --- | --- |
| `output/data.win` | `1431831521882ba858811a3ed8112d9d06fdbfa189ace407c5ec95082ea7c954` |
| `output/chapter1_windows/data.win` | `cc41dbb6061f811b1ede4516cfeef16132ea8970ec8afc02c1af17568181b344` |
| `output/chapter2_windows/data.win` | `8b551e5fdef4daa631c670e9b7bc9a8a72f60d90ab0af8b332fc8557e214fe3e` |
| `output/chapter3_windows/data.win` | `97221fbd145673c7fe2b4cc52edb5482765c77cc0ec0119b156c18151c60bbde` |
| `output/chapter4_windows/data.win` | `e15919bb864593b17db8e136d2f75efb3c44b1831850887bb9efbc6bb3b28487` |
| `output/chapter5_windows/data.win` | `87996269779bc98f8d517d2f963150f0de29ae545b23072280ab260905c6a2e5` |

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
