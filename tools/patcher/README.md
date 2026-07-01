# dr-tas-chs — DELTARUNE Keucher+CHS 共存安装器

一个**自带补丁数据、跨平台**的安装器:把研究得到的「Keucher Mod + 中文(CHS)共存」构建,以内嵌 xdelta 差分的形式,一键应用到用户自有的**纯净正版 DELTARUNE**。同一个二进制**无参数启动图形界面**,也提供命令行子命令。

> 本工具不含 DELTARUNE 本体。它只能应用到与构建时版本一致的**未修改**安装。内嵌数据派生自第三方作品,见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 用法

### 图形界面(面向普通玩家)

双击运行,或:

```bash
dr-tas-chs
```

流程:自动/浏览选择游戏目录 → 查看状态(纯净 / 已安装 / 版本不符)→ 勾选「安装前备份」→ 点「安装」→ 完成后可「卸载/还原备份」。

### 命令行

```bash
dr-tas-chs verify                     # 只检查状态,不改动
dr-tas-chs apply [-y] [--no-backup]   # 应用补丁(-y 跳过确认)
dr-tas-chs apply --dry-run            # 只演示计划
dr-tas-chs restore                    # 从最近一次备份回滚
# 均可加 --game-dir <路径>;未给则读 DELTARUNE_GAME_DIR,再自动探测 Steam 库
```

安装做的事:对 `data.win` 与各章 `chapterN_windows/data.win` 应用内嵌 xdelta;各章的结果同时写成 `data_keucher.win`(Keucher 章节选择会读它);铺放 CHS 的 `lang/`、`vid/`。安装前把将被覆盖的原文件备份到 `<游戏目录>/_dr_tas_chs_backup/<时间戳>/`。

### 安全保证

- 打补丁前逐文件校验 SHA256:只有确认是**纯净 vanilla**才动手;已是结果则幂等跳过;对不上任何已知值就**中止且不改动任何文件**(提示用 Steam「验证游戏文件完整性」还原)。
- 解码后再校验结果 SHA256,不符则中止。
- 幂等重跑不会覆盖指向 vanilla 的原始备份。

## 从源码构建

依赖:Rust 工具链、C 编译器(`xdelta3` crate 需要编译内含的 C 库)。Linux 上的文件夹选择框走 xdg-desktop-portal,**无需 GTK 开发包**。

内嵌数据(`tools/patcher/assets/`,已被 `.gitignore` 忽略)不在仓库里,构建前必须先生成:

```bash
export DELTARUNE_GAME_DIR=/path/to/纯净vanilla        # xdelta 的“源”,必须未修改且版本匹配
# 需要仓库根的 output/ 已包含合并结果(见 docs/REPRODUCING.md)
# 中文界面字体默认取 HarmonyOS Sans SC,可用 UI_FONT 覆盖
./scripts/gen_assets.sh

cargo build --release --manifest-path tools/patcher/Cargo.toml
# 产物:tools/patcher/target/release/dr-tas-chs(≈ 78 MB,自包含)
```

`gen_assets.sh` 会:用 `xdelta3 -e -9 -S djw` 生成 6 个差分(源窗口 `-B` 调到大于最大源文件),即时用 `xdelta3 -d` 回滚自校验;复制 `output/*/lang`、`*/vid`;复制中文字体;写 `assets/manifest.json`(含每个目标的源/结果 SHA256)。

## 跨平台发布

内嵌数据只能在同时拥有 vanilla 与 `output/` 的机器上生成。在 **Windows / macOS / Linux 各自**执行上面的「从源码构建」(先把 `scripts/gen_assets.sh` 产出的 `tools/patcher/assets/` 拷到对应机器,再 `cargo build --release`),各得一个自包含二进制:

- Linux：`dr-tas-chs`
- Windows：`dr-tas-chs.exe`（release 版不带控制台黑框;CLI 子命令仍会附着终端输出）
- macOS：`dr-tas-chs`（可用 `lipo` 合成 x86_64 + aarch64 通用二进制）

发布 release 时,建议随二进制附带 `THIRD_PARTY.md` 与 HarmonyOS Sans 许可证。
