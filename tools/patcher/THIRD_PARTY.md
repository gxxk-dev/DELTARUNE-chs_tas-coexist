# 第三方内容与授权

`dr-tas-chs` 安装器为**方便终端用户**而内嵌了若干第三方派生数据与库。使用/分发本工具即表示你已了解并遵守下列各方的授权。**本工具不包含、也不分发 DELTARUNE 本体;用户必须自行拥有正版游戏。**

## 内嵌的补丁数据(第三方派生)

内嵌的 `*.xdelta` 是「纯净 vanilla `data.win`」到「Keucher Mod + CHS 合并结果」的二进制差分,`lang/`、`vid/`、`mus/` 是 CHS 的外置资源。这些数据派生自:

- **DELTARUNE** © Toby Fox / 8-4。游戏本体不被分发;补丁只能应用到用户自有的、版本匹配的纯净安装。
- **Keucher Mod**(`v5.10.7`, commit `f3437becd845f34ce9cabe2709fb36e7e549a8be`)。savestate 与运行时钩子改动。版权归其作者。
- **DeltaruneChinese / CHS 汉化**(<https://github.com/gm3dr/DeltaruneChinese>, tag `260710`, commit `2d322c11d7b086e018bc8a9b823d18c80685d7f6`)。中文文本、字体、贴图、图集等。版权归汉化组。

> 分发内嵌这些差分的二进制,等于再分发上述第三方的派生作品。请在发布前确认你已获得相应授权或许可。

## 内嵌字体

- **HarmonyOS Sans SC** © Huawei Device Co., Ltd. 供图形界面显示中文。依据 HarmonyOS Sans 字体许可免费使用;分发时应随附其许可证文本。

## 使用的开源库(Rust crates)

| 库 | 许可 | 用途 |
| --- | --- | --- |
| `xdelta3`(xdelta3-rs) | Apache-2.0(内含 xdelta3 C 库,APL/GPL) | 应用 xdelta 差分 |
| `eframe` / `egui` | MIT OR Apache-2.0 | 图形界面 |
| `rfd` | MIT | 原生文件夹选择框 |
| `clap` | MIT OR Apache-2.0 | 命令行解析 |
| `sha2` / `serde` / `serde_json` / `hex` | MIT OR Apache-2.0 | 哈希 / 清单解析 |

各库许可证以其上游仓库为准。发布二进制时,建议在 release 附带本文件与 HarmonyOS Sans 许可证。
