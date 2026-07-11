# DELTARUNE TAS + CHS Coexist

本仓库提供一条统一的本地构建流水线：从玩家持有的干净 DELTARUNE 游戏文件出发，
源码构建 Keucher Mod，再把 DeltaruneChinese 与共存规则合入同一份最终输出。主仓库不
提交 DELTARUNE 文件、生成后的 `data.win` 或本地补丁集；三个上游以固定 commit 的 Git
submodule 形式引用。

当前锁定组合为：

- DELTARUNE PC `v0.0.247`，使用 Windows/Linux-Proton 游戏目录布局；
- [Keucher Mod](https://github.com/nhaar/keucher-mod) `f3437be`
  （`v5.10.7-1-gf3437be`）；
- [UMP](https://github.com/nhaar/UMP) `c08b817`（`v4.3.0`）；
- [DeltaruneChinese](https://github.com/gm3dr/DeltaruneChinese) `260710`
  （`2d322c1`）；
- UndertaleModTool CLI `0.9.1.1`。

构建输入必须精确匹配机器锁中的干净游戏文件。除通过包管理器安装的软件和本仓库源码
外，用户只需准备一份正版游戏本体，不再需要另找预制 Keucher 补丁或 CHS 发布包。

## 快速构建

先安装 [系统依赖](docs/DEPENDENCIES.md)，再克隆仓库：

```bash
git clone --recurse-submodules \
  https://github.com/gxxk-dev/DELTARUNE-chs_tas-coexist.git
cd DELTARUNE-chs_tas-coexist
./build.sh --game-dir "/path/to/clean/DELTARUNE"
```

普通在线构建也会初始化缺失的 submodule；使用 `--recurse-submodules` 可以更早暴露网络
或上游访问问题。不要使用 GitHub 自动生成的 Source ZIP，它没有构建器需要校验的 Git
gitlink 信息。

构建器会先校验游戏和 schema 2 版本锁，再检查三个 submodule 的固定 commit，下载并
校验固定 UndertaleModTool CLI，从源码生成六份 Keucher baseline，合入
DeltaruneChinese `260710` 与共存修复，最后完整验证并原子发布到 `output/`。游戏目录在
整个构建期间保持只读；旧 `output/` 只会在新结果全部通过后被替换。

首次成功后，可使用同一源码 checkout 和缓存离线重建：

```bash
./build.sh --game-dir "/path/to/clean/DELTARUNE" --offline
```

离线模式要求三个 submodule 已初始化，且各自的 Git object database 已包含锁定 commit；
工作树 `HEAD` 可以不同，因为构建器直接导出锁定对象。离线构建绝不会运行 clone/fetch，
缺少工作树或对象时会立即失败。

`./build.sh --help` 列出 `--output-dir`、`--cache-dir`、`--work-dir` 和 `--keep-work` 等
选项。临时工作目录至少需要 4 GiB 可用空间。

## 安装与还原

构建不会自动修改游戏。确认 `output/` 后显式安装：

```bash
./install_output.sh apply --game-dir "/path/to/clean/DELTARUNE"
```

安装器重新读取 schema 2 版本锁与 `build-info.json`，校验输出后只写入 34 个白名单目标，
并在 `backups/` 创建逐文件记录的事务备份。其中 Chapter 1-5 的最终 `data.win` 还会各自
复制为 `data_keucher.win`，供 Keucher chapter selector 使用。

还原最近一次安装：

```bash
./install_output.sh restore --game-dir "/path/to/DELTARUNE"
```

也可用 `--backup DIR` 指定备份。还原不会覆盖安装后又被用户或其他 Mod 修改的文件。

## 本地补丁集

需要保存一次完整的 vanilla-to-final 构建结果时，可同时生成本地 BPS 补丁集：

```bash
./build.sh \
  --game-dir "/path/to/clean/DELTARUNE" \
  --patchset-dir ./patchset
```

构建器会自动下载并校验固定的 Flips v198 Linux 工具，无需系统安装 `flips`。补丁集包含
六份 BPS、外置语言/音视频文件、逐文件哈希和来源 commit，并在发布前执行回放验证。
这些内容由游戏和第三方资源派生，只能在用户本机留存；不要提交或发布该目录。

## 版本与复现

当前机器锁是
[`versions/pc-v0.0.247-f3437be-260710.json`](versions/pc-v0.0.247-f3437be-260710.json)。
它记录干净游戏输入、submodule 路径/URL/commit、工具归档及关键成员、适配器、Keucher
中间结果和最终输出的哈希。源码适配器以 `--fuzz=0` 应用，NuGet 使用锁文件；
`output/build-info.json` 另记录本次构建实际使用的来源 commit 和工具版本。

Ch5 开场 OGG 由机器锁固定的 WAV 使用系统 FFmpeg/libvorbis 生成。构建器验证 codec、
采样率、声道、时长和锁定的 Chromaprint 内容指纹，并把本机生成文件的 bytes/SHA256
写入 `build-info.json`；安装器和补丁集据此复核两份副本。不同发行版的
FFmpeg/libvorbis 可能产生不同容器字节，因此跨环境逐字节复现目标是六个最终
`data.win` 和 21 个静态外置文件。

详细流水线、离线前提和研究结论见
[docs/REPRODUCING.md](docs/REPRODUCING.md)。

## 仓库边界

仓库跟踪构建/安装脚本、适配器、schema 2 版本锁、`DataWinProbe`、上游 gitlink 和紧凑
验证记录。以下内容只在本机生成并由 `.gitignore` 排除：

- `build/`、`work/`、`output/`、`backups/` 和本地补丁集；
- 游戏 `*.win`、BPS、音视频、字体和工具下载归档；
- NuGet、Wine 和下载缓存。

提交或发布前运行：

```bash
./scripts/check_version_lock.sh
./scripts/check_publish_tree.sh
git diff --check
```

`tools/patcher/` 是早期自包含补丁器原型，不是当前交付路径；本项目不发布其派生资源或
带资源二进制。
