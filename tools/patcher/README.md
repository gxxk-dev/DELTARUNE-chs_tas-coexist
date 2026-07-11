# Legacy self-contained patcher prototype

`tools/patcher/` 保留早期 Rust GUI/CLI 安装器的源码，仅用于研究历史。它依赖由游戏本体和
合并输出生成的 xdelta、语言、视频、音频与字体资源；这些资源位于被忽略的
`tools/patcher/assets/`，不属于仓库内容。

当前支持的交付路线是仓库根目录的 [`build.sh`](../../build.sh)：用户提供干净正版游戏，
脚本在本机从锁定上游构建 `output/`，再由 [`install_output.sh`](../../install_output.sh)
显式安装和事务还原。

本项目不会发布此原型的带资源二进制。把生成资源嵌入补丁器会构成第三方派生内容的再
分发；任何独立研究都必须先处理 [THIRD_PARTY.md](THIRD_PARTY.md) 中列出的授权问题。
