# 系统依赖

当前构建器支持 Ubuntu 24.04+ 与 Arch Linux 主机。它处理的是 DELTARUNE PC
`v0.0.247` 的 Windows 数据目录，也适用于 Linux/Proton 安装，但构建流程本身需要 Linux、
Bash、.NET SDK 10 和 Wine。

所有需要用户配置的工具都能直接通过 `apt` 或 `paru` 安装。默认构建除本仓库及其
submodule 外，只需用户提供一份正版、干净的 DELTARUNE 游戏目录；可选 Ralsei 肖像变体
还需要用户自行合法取得并显式传入锁定的 7z 归档。当前流程不需要 Node.js、Rust、
Python、额外补丁器、Xvfb 或系统 `flips`。

## Ubuntu 24.04+

.NET 10 可从 Ubuntu .NET Backports PPA 安装；已经配置 Microsoft APT 软件源的用户也可
直接安装同名软件包。不要使用 `dotnet-install.sh`，本项目只要求包管理器维护的 SDK。

```bash
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y universe
sudo add-apt-repository -y ppa:dotnet/backports
sudo apt update
sudo apt install -y \
  bash ca-certificates coreutils curl diffutils dotnet-sdk-10.0 ffmpeg \
  findutils gawk git grep jq libchromaprint-tools patch perl ripgrep sed tar \
  7zip unzip util-linux wine
```

如果系统已经配置 Microsoft APT 软件源，可跳过添加 PPA 的步骤，直接执行最后一条
`apt install`。

## Arch Linux

Wine 位于 Arch 的 `multilib` 仓库。启用该仓库后执行：

```bash
paru -S --needed \
  bash ca-certificates chromaprint coreutils curl diffutils dotnet-sdk ffmpeg findutils \
  gawk git grep jq patch perl ripgrep sed tar 7zip unzip util-linux wine
```

Arch 是滚动发行版；安装后 `dotnet --version` 的主版本必须为 `10` 或更高。

## 环境检查

```bash
dotnet --version
wine --version
ffmpeg -version | head -n1
fpcalc -version
jq --version
git --version
command -v 7zz || command -v 7z
```

`build.sh` 会在读取游戏内容前检查所需命令，并拒绝低于 .NET 10 的 SDK。`7zz` / `7z`
只在传入 `--ralsei-archive` 时用于检查并提取白名单文件；Ubuntu 与 Arch 的 `7zip` 均可
由上述包管理器直接安装。构建器优先使用 `7zz`，并兼容提供旧命令名的 `7z`。

## 获取源码

必须使用 Git clone，以便版本锁校验 submodule gitlink、路径和 URL。推荐一次取得所有固定
上游：

```bash
git clone --recurse-submodules \
  https://github.com/gxxk-dev/DELTARUNE-chs_tas-coexist.git
cd DELTARUNE-chs_tas-coexist
git submodule status
```

已有主仓库 checkout 可执行：

```bash
git submodule update --init --recursive
```

在线构建会尝试初始化缺失 submodule，并确保机器锁 commit object 可用。离线模式不运行
任何 clone/fetch，因此三个 submodule Git 仓库必须已经存在，并各自包含锁定 commit；
工作树 `HEAD` 可以不同，构建器直接从锁定 object 导出源码。GitHub Source ZIP 不包含
gitlink 元数据，不是受支持的交付形式。

当前三个 submodule 为：

- `upstream/keucher-mod`：Keucher Mod 源码；
- `upstream/UMP`：Keucher 构建使用的固定 `ump.csx`；
- `upstream/DeltaruneChinese`：`260710` 汉化源码、工作区和上游媒体。

## 自动管理的工具

以下工具或内容由版本锁管理，用户不需要手工下载或加入 `PATH`：

- UndertaleModTool CLI `0.9.1.1` 的 Ubuntu/Linux 归档，用于从 Keucher 源码生成六份
  `data.win`；
- Flips v198 Linux 归档，仅在指定 `--patchset-dir` 时用于创建并回放验证 BPS；
- DeltaruneChinese submodule 中固定的 BMFont Windows 工具，由系统 Wine 执行；
- `adapters/deltarune-chinese-260710.packages.lock.json` 固定的 NuGet 依赖。

下载归档、归档内关键成员和源码 commit 都会在使用前校验。工具下载损坏时在线模式会
重新获取，离线模式则直接失败。

可选肖像归档中附带的 Windows UndertaleModTool 不属于工具链，也不会被解包或执行；导入
始终使用主版本锁管理的 UndertaleModTool CLI `0.9.1.1`。

## 游戏输入

输入目录必须包含机器锁对应的以下文件：

```text
data.win
chapter1_windows/data.win
chapter2_windows/data.win
chapter3_windows/data.win
chapter4_windows/data.win
chapter5_windows/data.win
chapter5_windows/vid/ch5_intro_jp.mp4
```

脚本要求这些文件精确匹配 DELTARUNE PC `v0.0.247`。已经安装汉化、Keucher 或其他 Mod
的目录会在 submodule 初始化和工具下载前被拒绝；请另备一份干净游戏本体。构建不会向
该目录写入文件，安装必须随后显式执行 `install_output.sh apply`。

### 可选本地肖像输入

要构建 Ralsei 肖像变体，先观看
[BV1mNMv6NEiY](https://www.bilibili.com/video/BV1mNMv6NEiY)，按视频中的作者说明自行合法下载
`Samuton.Ver Ralsei Portrait Texture Replacement Pack.7z`，然后使用
`--ralsei-archive FILE`。仓库和构建器都不会代为下载或缓存这份版权资产。归档必须匹配
[`versions/ralsei-portraits-samuton-v1.json`](../versions/ralsei-portraits-samuton-v1.json)
记录的大小与 SHA256；导入器只读取清单列出的 `Replace/*` PNG，忽略归档内的其他内容。
输入路径不会写入 `build-info.json`。

## 网络、缓存与磁盘

首次 clone 会从 GitHub 获取三个固定 submodule，其中 DeltaruneChinese 包含构建所需
媒体，体积明显大于另外两个。首次在线构建还会访问 GitHub Releases 获取固定 UTMT CLI、
访问 NuGet 获取锁定包；只有请求本地补丁集时才会额外获取 Flips。

`--ralsei-archive` 指向的文件始终由用户在本地提供；在线和离线模式都不会为它发起网络
请求，也不会把它复制进下载缓存。

默认缓存位于 `${XDG_CACHE_HOME:-$HOME/.cache}/dr-tas-chs`，包含下载、NuGet 包和 Wine
prefix。下载使用可续传的 `.part` 文件，并在命中缓存时重新校验大小和 SHA256。

要使用 `--offline`，必须同时满足：

- 三个 submodule 已初始化，且各自的 Git object database 已包含版本锁 commit；
- UTMT CLI 归档和所有 NuGet 包已在指定缓存中；
- 若同时使用 `--patchset-dir`，Flips 归档也已由此前的在线补丁集构建缓存。

离线构建 Ralsei 变体时仍需显式传入本地归档；它不属于联网缓存前提。

离线 NuGet restore 会清空远程 package source；缺失、损坏或版本不符时不会静默联网或
回退到其他版本。

临时工作目录至少需要 4 GiB 可用空间。默认值为 `${TMPDIR:-/tmp}`；自定义
`--work-dir` 只能包含 ASCII 字母、数字、`_`、`.`、`/` 和 `-`。游戏、输出、补丁集、
缓存和工作目录参数本身不能是符号链接。输出与补丁集必须和游戏
目录完全不相交，也不能彼此重叠；缓存和工作目录不能位于游戏目录内部，但允许作为游戏
fixture 的祖先（例如 `/tmp`）。缓存/工作目录也不能与输出或补丁集重叠。任何写入路径若
位于本仓库内，都必须已被 `.gitignore` 覆盖；推荐使用 `output/`、`patchset/`、`work/`。
