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
| `output/chapter1_windows/data.win` | `b45e1555a96cc82be8200315716b5de3bfcd41acb0eac85407415fd2aa42b31d` |
| `output/chapter2_windows/data.win` | `ea86de7e44ce1c557fa5599346d3372d5c39114e26ef30ed25928580673ea343` |
| `output/chapter3_windows/data.win` | `a16f79336d2c7d981c1d89842efde2493aae03a5d38ff263514fde5de587c609` |
| `output/chapter4_windows/data.win` | `15ffd455c030fd4beb60e5971b6fb220f49fb88124f4e344a9e6b039369c302b` |
| `output/chapter5_windows/data.win` | `31a6d51050a10143a2f9842043c9e20b87577332de0fed4931012b60b0084c9b` |

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
