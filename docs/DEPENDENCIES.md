# Dependencies

这个仓库不发布 DELTARUNE、Keucher/TAS Mod、CHS patch 或任何生成后的 `data.win`。复现者需要自己准备正版游戏和第三方 Mod/patch 文件。

## Required local assets

### DELTARUNE full game

需要正版 DELTARUNE 安装目录，至少包含：

- `data.win`
- `chapter1_windows/data.win`
- `chapter2_windows/data.win`
- `chapter3_windows/data.win`
- `chapter4_windows/data.win`
- `chapter5_windows/data.win`

默认脚本使用环境变量：

```bash
export DELTARUNE_GAME_DIR="/path/to/DELTARUNE"
```

### Keucher/TAS Mod

本研究使用 Keucher Mod `v5.10.5` 的 PC patches：

| File | SHA256 |
| --- | --- |
| `patch_files/ch5_latest-chapter_select.bps` | `328f7ba64ac3b85e62383015f00930d4d5a0ff8d5a5b7fa3deb64249f4891590` |
| `patch_files/ch5_latest-chapter1.bps` | `3840d43c0615ebf4ea124c3eab42251ff52f4553eaed49c2a9a2d2504ce249a3` |
| `patch_files/ch5_latest-chapter2.bps` | `7a8f7e1e4faf0a28373ca8d6ed91aae1f1310d341af3f983560840cb5e315657` |
| `patch_files/ch5_latest-chapter3.bps` | `7225ddc3b5322da2c86d60ff4c64f0d42b0d5ae08af81caf98f640dde0f2f075` |
| `patch_files/ch5_latest-chapter4.bps` | `8d7214d79e6f4d59424092c7076614b132cffaf22fb452919dcd393be94a866d` |
| `patch_files/ch5_latest-chapter5.bps` | `310ee1028c609d854d8816187cfad4e0c16b79b44b55d964e807465c947d218e` |

默认脚本使用环境变量：

```bash
export KEUCHER_MOD_DIR="/path/to/Keucher.Mod.v5.10.5"
```

### DeltaruneChinese source

本研究使用：

- Repository: `https://github.com/gm3dr/DeltaruneChinese.git`
- Commit: `a43a1ec74d2af9a63d6fddc97b8fef708a1a941f`

默认脚本使用环境变量：

```bash
export DELTARUNE_CHINESE_DIR="/path/to/DeltaruneChinese"
```

### CHS release data

本研究使用的 CHS release package 包含外置 `lang/`、`vid/` 和 `.xdelta` files。已记录的 `.xdelta` SHA256：

| File | SHA256 |
| --- | --- |
| `main.xdelta` | `b769a848b3adc0cf22d39bcf8c1f014782f9c4f4d0d20a2810f284d12d3ff727` |
| `chapter1.xdelta` | `db2af8926cbe372c94a53dcaac894c2b822632d86fda8f6a43bd2fd17e909f84` |
| `chapter2.xdelta` | `40b1eb028da3f32e928e8d2438d9bada771c5492dc414f775c17770c04ba0840` |
| `chapter3.xdelta` | `5e641eb9f824dc72aaa15a37d7891303dac2d9deefe6e151a3b038c4ff6f5184` |
| `chapter4.xdelta` | `98e1f7ef1c7d37fcc83acd804f2ad27b29107ee2d0285fe71be57f4db669b50c` |

默认脚本使用环境变量：

```bash
export CHS_RELEASE_DIR="/path/to/dr-ch-patch-290629-.5"
```

### RomPatcher.js

`scripts/apply_bps.js` 需要 RomPatcher.js 的 CommonJS modules：

```bash
export ROMPATCHER_JS="/path/to/RomPatcher.js/rom-patcher-js"
```

## Local-only outputs

以下路径是本地生成/安装用，不应提交到 GitHub：

- `build/`
- `output/`
- `backups/`
- `work/`
- `latest_backup.txt`
