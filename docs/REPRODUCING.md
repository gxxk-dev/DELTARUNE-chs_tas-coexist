# 可复现构建说明

当前构建 ID 为 `pc-v0.0.247-f3437be-260710`。schema 2 机器锁
[`versions/pc-v0.0.247-f3437be-260710.json`](../versions/pc-v0.0.247-f3437be-260710.json)
是版本、大小、SHA256、来源路径和输出集合的唯一事实源。

## 锁定来源

| 组件 | 仓库路径或交付形式 | 锁定版本 |
| --- | --- | --- |
| Keucher Mod | `upstream/keucher-mod` submodule | `f3437becd845f34ce9cabe2709fb36e7e549a8be` |
| UMP | `upstream/UMP` submodule | `c08b817ad2e8ba1e7da481e468c1881f9ded7ad5` |
| DeltaruneChinese | `upstream/DeltaruneChinese` submodule | tag `260710` / `2d322c11d7b086e018bc8a9b823d18c80685d7f6` |
| UndertaleModTool CLI | 经校验的 GitHub Release 归档 | `0.9.1.1` |
| Flips | 仅补丁集流程下载的 Linux 归档 | `v198` |

submodule commit 才是源码身份；tag 和短版本号只用于阅读。`check_version_lock.sh` 同时
校验 gitlink、`.gitmodules` 中的路径/URL、适配器大小与哈希及 NuGet lock 结构。

## 准备 checkout

```bash
git clone --recurse-submodules \
  https://github.com/gxxk-dev/DELTARUNE-chs_tas-coexist.git
cd DELTARUNE-chs_tas-coexist
./scripts/check_version_lock.sh
```

构建必须在 Git checkout 中运行。GitHub Source ZIP 缺少 submodule gitlink，无法通过来源
校验。已有 checkout 可先运行 `git submodule update --init --recursive`。

## 统一构建流程

```bash
./build.sh --game-dir "/path/to/clean/DELTARUNE"
```

流水线按以下顺序执行：

1. 验证 schema 2 版本锁、三个 gitlink、`.gitmodules`、适配器和 NuGet lock，再校验干净
   游戏的六个 `data.win` 与 Ch5 日文视频。游戏不匹配时不会开始下载。
2. 确认 Keucher、UMP 与 DeltaruneChinese 的锁定 commit object 可用；离线模式要求三个
   submodule Git 仓库已经存在且绝不运行 clone/fetch，在线模式才会初始化缺失仓库或获取
   缺少的 object。
3. 将 Keucher commit 导出到临时目录，从 UMP commit 取出并再次哈希固定 `ump.csx`，以
   `--fuzz=0` 应用 Linux/确定性适配器。
4. 下载并校验 UndertaleModTool CLI `0.9.1.1` 归档及关键成员，分别用 Keucher 的 chapter
   select、Chapter 1-5 源码脚本处理六份原版 `data.win`；每个 Keucher baseline 必须匹配
   机器锁中的 SHA256。
5. 导出 DeltaruneChinese `260710` commit，以 `--fuzz=0` 应用共存适配器并安装仓库固定的
   `packages.lock.json`，然后把六份 Keucher baseline 放入其 workspace。
6. 移除会覆盖 Savestates v2.1 manager 的旧 import，给 initializer、readable-room 和 Ch5
   town event 合入 loading guard / `mod_init()` 规则；同时验证 `260710` 已原生包含
   DELTARUNE Ch5 `v0.0.247` credits、版本号、Terracota timer 与 cliff-scene 修复。
7. 使用 `dotnet restore --locked-mode` 和 .NET 10 构建 CHS packer，再对 Keucher baseline
   导入中文代码、字体、贴图、文本及上游媒体。
8. 对 packer 结果重新注入 Keucher Savestates v2.1 wrappers/loading guards，随后应用
   savestate performance、Ch5 pause 和 rhythm-evaluation font 热修。
9. 组装语言 JSON、视频，并从固定 WAV 生成两份内容相同的 Ch5 Vorbis OGG。
10. 校验所有固定哈希、音频属性、Chromaprint 内容指纹、关键反编译代码与输出文件集合，写入 schema 2
    `build-info.json`；若指定 `--patchset-dir`，此时创建并回放验证本地补丁集。全部成功后
    才原子替换目标 `output/`。

任何构建失败都不会写入游戏目录。已存在的输出在新 staging tree 完整通过前保持不变；
发布期间的普通中断会触发旧目录恢复。

## 在线与离线复现

先用固定缓存执行一次在线构建：

```bash
./build.sh \
  --game-dir "/path/to/clean/DELTARUNE" \
  --cache-dir "$HOME/.cache/dr-tas-chs"
```

随后可在同一 checkout 上禁用下载和远程 NuGet source：

```bash
./build.sh \
  --game-dir "/path/to/clean/DELTARUNE" \
  --cache-dir "$HOME/.cache/dr-tas-chs" \
  --output-dir /tmp/dr-tas-chs-output-offline \
  --offline
```

离线模式要求三个 submodule Git 仓库已经初始化、各自 object database 已包含固定 commit、
UTMT 归档完整且锁定 NuGet 包已经缓存。工作树 `HEAD` 可以处于其他 commit，构建器直接
导出锁定 object；它不会 clone/fetch、回退到其他版本或接受损坏缓存。下载使用稳定
`.part` 文件，在线重试可以续传。

若离线构建还需要 `--patchset-dir`，应先至少在线执行一次带该参数的构建，使锁定 Flips
归档进入同一缓存；普通在线构建不会为未请求的可选功能预下载 Flips。

## 本地补丁集

```bash
./build.sh \
  --game-dir "/path/to/clean/DELTARUNE" \
  --output-dir ./output \
  --patchset-dir ./patchset
```

构建器从版本锁下载并校验 Flips v198 Linux 归档，不依赖系统 `flips`。补丁集包含：

- `patches/`：main 与 Chapter 1-5 的 vanilla-to-final BPS；
- `extras/`：语言、视频和生成音频等无法放入 `data.win` 的文件；
- `manifest.json`：完整来源、输入/输出/BPS 哈希、文件大小，以及五条
  `derived_copies` 形式的 `data_keucher.win` 复制规则；
- `README.txt`：独立回放顺序。

每份 BPS 创建后都会立即应用到对应干净输入，并检查结果 SHA256。补丁集由游戏本体与
第三方资产派生，只用于持有者本机归档或研究，不得加入 Git、Release 或其他分发物。

## 输出验证边界

跨环境固定输出包括六个最终 `data.win` 和 21 个静态外置文件，后者为语言 JSON 与视频；
它们全部按机器锁校验字节数（适用时）与 SHA256。源 WAV 同样锁定 bytes/SHA256。两份
构建生成的 Ch5 OGG 必须内容相同，并验证 Vorbis codec、48 kHz、双声道、时长和相对
锁定源 WAV 至少 `0.99` 的 Chromaprint 位相似度。这样允许不同 libvorbis 产生不同容器，
同时拒绝仅伪造技术属性的静音或无关音频。

`scripts/verify_merged_output.sh` 会反编译关键代码，验证 Savestates v2.1、Flowery boss
practice、initializer/readable-room guards、Ch5 pause 和 rhythm font 修复。输出树只允许
版本锁声明的普通文件、必需父目录及 `build-info.json`，符号链接、特殊文件和额外空目录
都会被拒绝。

`build-info.json` 绑定构建 ID、上游/适配器/UTMT provenance、构建环境版本、六个固定
输出哈希，以及本机 OGG 的 bytes/SHA256。安装器与补丁集只接受和这份声明一致的两份
音频副本，并再次检查音频属性与内容指纹。构建时间、环境版本和 OGG 容器不承诺跨环境逐字节相同；
不同 `apt` / `paru` FFmpeg/libvorbis 版本产生不同哈希是允许的。

## 显式安装测试

安装与构建分离。对隔离的游戏副本执行：

```bash
./install_output.sh apply --game-dir "/path/to/test/DELTARUNE"
./install_output.sh apply --game-dir "/path/to/test/DELTARUNE"   # 幂等检查
./install_output.sh restore --game-dir "/path/to/test/DELTARUNE"
./install_output.sh restore --game-dir "/path/to/test/DELTARUNE" # 幂等检查
```

安装清单来自同一 schema 2 版本锁。六份最终 `data.win`、Chapter 1-5 的五份
`data_keucher.win`、21 个静态外置文件和两份生成音频合计 34 个目标。备份 manifest 记录
每个目标安装前状态、原哈希和安装哈希；备份还会绑定当前 build ID、完整目标集合和事务
状态。安装后被其他程序修改的文件不会被还原流程覆盖。

安装器处理普通错误、`Ctrl-C` 和 `TERM`，但 Bash 无法把断电、`SIGKILL` 或同一用户的
恶意并发进程纳入完整事务边界。异常掉电后若游戏根目录残留
`.dr-tas-chs-install.lock`，先确认没有安装器进程，再检查最新备份的 `status`。对
`APPLYING` 备份可移除空锁目录并显式运行：

```bash
./install_output.sh restore \
  --game-dir "/path/to/test/DELTARUNE" \
  --backup "/path/to/that/backup"
```

不要在安装器仍运行时手工删除锁。

## 维护者检查

不含版权资产的静态检查可在任意完整 Git clone 或公共 CI 中运行：

```bash
bash -n build.sh install_output.sh
find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
./scripts/check_version_lock.sh
./scripts/check_publish_tree.sh
git diff --check
```

完整构建和补丁集回放需要维护者提供合法游戏输入，因此公共 CI 只执行静态检查。

## 关键兼容结论

- 面向原版 `data.win` 的既有成品差分不能直接套到 Keucher 输出；当前路线从固定源码生成
  Keucher baseline，再针对该 baseline 运行 DeltaruneChinese importer。
- Keucher `f3437be` 使用独立 Savestates v2.1 注入；旧 manager import 会将其覆盖回 v1，
  因此必须移除旧 import，并在 CHS code replacement 后重新插桩。
- Chapter 1-5 initializer 必须保留 loading guard 与 `mod_init();`；readable-room Step 必须在
  读档期间退出并为 `myinteract` 提供 fallback。
- DeltaruneChinese `260710` 已包含 Ch5 `v0.0.247` credits/version/timer/cliff-scene 更新，
  构建器将其作为锁定前提验证；最终结果还需让 savestate manager 常驻并安全处理 boss
  room 的 Pause/`obj_time`。
- Keucher chapter selector 加载 `data_keucher.win`；安装和补丁集 manifest 都必须让每章
  该文件与最终 `data.win` 完全一致。
