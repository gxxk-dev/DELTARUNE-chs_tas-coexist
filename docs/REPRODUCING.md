# Reproducing the Research Build

这份说明记录研究复现路线。仓库不包含游戏资产、Mod patches、CHS release data 或最终 `data.win`。

## High-level process

1. 从正版 DELTARUNE 读取原始 `data.win` files。
2. 使用 Keucher/TAS Mod 的 `.bps` patches 生成 TAS baseline。
3. 使用 DeltaruneChinese packer，以 TAS baseline 作为输入导入 CHS resources。
4. 对冲突 GML 保留 Keucher/TAS runtime hooks。
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
- 每个 `chapterN_windows/data_keucher.win` 应与对应的 merged `chapterN_windows/data.win` byte-for-byte 一致。

## Expected final output hashes

当前成功构建的 final output SHA256：

| File | SHA256 |
| --- | --- |
| `output/data.win` | `1431831521882ba858811a3ed8112d9d06fdbfa189ace407c5ec95082ea7c954` |
| `output/chapter1_windows/data.win` | `546b5be82c3f39775fd9ad13bdd7dd705186c1461dd22c18dac8ed0d8e4ebec5` |
| `output/chapter2_windows/data.win` | `c216f1e0058418f2ce392104f9e01fa977ee1bb10763b34f815954c11ac218de` |
| `output/chapter3_windows/data.win` | `c0621c33ccc514657b34ab1411766a0fc524391c20de76e6cc1db937a8f15948` |
| `output/chapter4_windows/data.win` | `316eed82f924b7bca13ad61c6f047cf17f4bf8bb4ed9cd531c1cefb9d30e0225` |
| `output/chapter5_windows/data.win` | `b9ba21b728e06fa616924c4dd3511ada31dfd7ba371f4053ec5eea61682fbe4f` |

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
