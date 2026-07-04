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
- Commit: `5f95b0d1d16f80c267eefb6a9ccfd039b0800e0c`

默认脚本使用环境变量：

```bash
export DELTARUNE_CHINESE_DIR="/path/to/DeltaruneChinese"
```

### CHS release data

本研究使用的 CHS release package 包含外置 `lang/`、`vid/` 和 `.xdelta` files。已记录的 `.xdelta` SHA256：

| File | SHA256 |
| --- | --- |
| `main.xdelta` | `2e9d26760203b92cb67fa99d6e28300d02664976e29a9e45fca098e8ef9b9461` |
| `chapter1.xdelta` | `2e1083219227b371938012a36c776a5790ced8fa403b45b02094eb9c7c1396a9` |
| `chapter2.xdelta` | `a98580c4febbcae62d4fac457fa53178a37c01145dc37aa0efe58ede0bd2b392` |
| `chapter3.xdelta` | `620c3239156a38f9559b0fc5c86ffccb25be192a43352e33b57f27ee0e17ef01` |
| `chapter4.xdelta` | `4563d9b6765fbc790e2367765b3b4dca7b3da2da2c1e27cecd6929f2684529bf` |
| `chapter5.xdelta` | `15627d6912ac2226dab8ff7fac14c3442013f5abbb504262ec955b6203ca92d4` |

默认脚本使用环境变量：

```bash
export CHS_RELEASE_DIR="/path/to/dr-ch-patch-260704-including-ch5"
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
