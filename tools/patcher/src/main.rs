// release 版在 Windows 上不弹控制台黑框(GUI 模式);CLI 子命令会在 main() 里附着父进程控制台。
#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod assets;
mod backup;
mod cli;
mod engine;
mod gamedir;
mod gui;
mod manifest;

use clap::{Args, Parser, Subcommand};
use std::path::PathBuf;
use std::process::ExitCode;

#[derive(Parser)]
#[command(
    name = "dr-tas-chs",
    version,
    about = "DELTARUNE Keucher Mod + CHS 共存补丁安装器(自带补丁数据,跨平台;无参数启动图形界面)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Option<Cmd>,
    /// 游戏根目录;未给则自动探测,也可用环境变量 DELTARUNE_GAME_DIR
    #[arg(long, global = true)]
    game_dir: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Cmd {
    /// 启动图形安装器(默认)
    Gui,
    /// 命令行应用补丁
    Apply(ApplyArgs),
    /// 仅检查当前安装状态,不改动任何文件
    Verify,
    /// 从备份回滚(默认用最近一次)
    Restore(RestoreArgs),
}

#[derive(Args)]
struct ApplyArgs {
    /// 跳过交互确认
    #[arg(short = 'y', long)]
    yes: bool,
    /// 不创建备份(不推荐)
    #[arg(long)]
    no_backup: bool,
    /// 只演示计划,不写任何文件
    #[arg(long)]
    dry_run: bool,
}

#[derive(Args)]
struct RestoreArgs {
    /// 指定备份目录(默认读取 latest.txt)
    #[arg(long)]
    backup: Option<PathBuf>,
}

fn main() -> ExitCode {
    // 从终端启动 CLI 子命令时附着父进程控制台,让输出可见;双击启动 GUI 时无父控制台,静默失败即可。
    #[cfg(target_os = "windows")]
    unsafe {
        use windows_sys::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }

    let cli = Cli::parse();
    let result = match cli.cmd {
        None | Some(Cmd::Gui) => gui::run(),
        Some(Cmd::Apply(a)) => cli::apply(cli.game_dir, a.yes, a.no_backup, a.dry_run),
        Some(Cmd::Verify) => cli::verify(cli.game_dir),
        Some(Cmd::Restore(r)) => cli::restore(cli.game_dir, r.backup),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("\n错误: {e}");
            ExitCode::FAILURE
        }
    }
}
