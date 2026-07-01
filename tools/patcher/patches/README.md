# 交叉编译 patch:xdelta3 0.1.5(Linux → Windows)

`xdelta3` 0.1.5(本安装器唯一的 C 绑定依赖)对交叉编译不友好。本目录的
`xdelta3-0.1.5-cross-windows.patch` 固化了在 Linux 上交叉编译到
`x86_64-pc-windows-gnu`(mingw-w64)时踩到的修法,便于日后复现或继续推进。

## patch 修了什么

1. **探测程序漏 `.exe`(已修,有效)**
   `check_native_size` 会编译并运行一个探测 `sizeof` 的小程序。原代码用
   `#[cfg(windows)]`(**主机**判断)决定是否加 `.exe`;但 mingw gcc 会自动给输出
   补 `.exe`,于是 Linux 上产物是 `test-N.exe`,而代码却去执行 `test-N` → ENOENT。
   改为按 `CARGO_CFG_TARGET_OS`(**目标**)判断。探测程序经 binfmt_misc → wine 运行。

2. **bindgen 误用主机头文件(已修,有效)**
   bindgen 未指定 target/sysroot,clang 默认拉主机 `/usr/include`,与 mingw 的
   `corecrt.h` typedef 冲突。改为交叉到 windows 时注入
   `--target=x86_64-pc-windows-gnu --sysroot=/usr/x86_64-w64-mingw32`。

3. **bindgen 0.52 → 0.70(为绕开崩溃,但引出死结)**
   老 bindgen 0.52 撞上新 libclang(22)会崩。升级后 API 改名
   (`whitelist_function` → `allowlist_function`、`CargoCallbacks::new()`)。

## 尚未解决的死结

升级 bindgen 后,生成的 Windows 绑定里结构体布局残缺(`_xd3_stream` 等被当成
不透明类型,`size_of == 1`),布局断言直接编译失败。**强行关掉断言能编过,但
Windows 版结构体布局是错的,运行时会静默损坏打出来的 data.win——因此不能用。**

结论:**Linux → Windows 交叉当前不可行**。Windows / macOS 二进制请走原生编译
(真机 `cargo build --release`,或 GitHub Actions 的 `windows-latest` /
`macos-latest` runner)——`xdelta3` 在自己的系统上原生编译没有上述任何问题。

## 如何应用(若要继续尝试)

```bash
# 1. 把 crate 从只读的 registry 缓存复制到可写目录
src=~/.cargo/registry/src/*/xdelta3-0.1.5
cp -r $src /tmp/xdelta3-patched && chmod -R u+w /tmp/xdelta3-patched

# 2. 应用本 patch
patch -p1 -d /tmp/xdelta3-patched < tools/patcher/patches/xdelta3-0.1.5-cross-windows.patch

# 3. 预热 wine(首次运行探测程序需要已初始化的默认 prefix)
WINEDEBUG=-all wine cmd /c "echo warm"; wineserver -w

# 4. 用 [patch] 注入并交叉构建(会卡在上面的死结)
export RUSTFLAGS="-C link-args=-static -C link-args=-static-libgcc -C link-args=-static-libstdc++"
cargo build --release --target x86_64-pc-windows-gnu \
  --config 'patch.crates-io.xdelta3.path="/tmp/xdelta3-patched"'
```

前置依赖:`mingw-w64`、`wine` + binfmt_misc(magic `4d5a` → wine)、`libclang`。
