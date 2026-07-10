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

本研究使用 Keucher Mod `v5.10.7` 的 PC patches。官方 Release ZIP（2026-07-09 上传）的 SHA256 为 `1c4499a11cb93c2b8e3d60d4fa0d1bcd15467e5f48581df2333cab0bf8b8fb2b`：

| File | SHA256 |
| --- | --- |
| `patch_files/ch5_latest-chapter_select.bps` | `77fb87c615264138b595752ceadcb652e2b2a3860fb7ae7b11871feec0225a21` |
| `patch_files/ch5_latest-chapter1.bps` | `014c730c165c75f97abfb99c72a35c5770f67c99dae8b1b0a8cfc5b560103ff5` |
| `patch_files/ch5_latest-chapter2.bps` | `ea84926aa491acf77bde18ba8f550de3c570f405e4aa85e4c27e408371f5b7c9` |
| `patch_files/ch5_latest-chapter3.bps` | `249e5af31336ccb550905e6850696bab25caac49e208f63779b8a86ba98e5986` |
| `patch_files/ch5_latest-chapter4.bps` | `6806801a189e0d6486cef614ea85af15a12d8a4bee007c7ef5d76fbfb732db9a` |
| `patch_files/ch5_latest-chapter5.bps` | `48071d643504e9fd21989719e689dcda3744de0fd7db009cf79c64566960fcbe` |

默认脚本使用环境变量：

```bash
export KEUCHER_MOD_DIR="/path/to/Keucher.Mod.v5.10.7"
```

### DeltaruneChinese source

本研究使用：

- Repository: `https://github.com/gm3dr/DeltaruneChinese.git`
- Commit: `824524b6c86b4b902ba13ee6c5483f3cfeef3cec`

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
