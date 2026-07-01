// 命令行界面:薄封装,调用 engine 并把结果打印到终端。
use crate::engine::{self, ApplyOptions, Progress};
use std::io::Write;
use std::path::PathBuf;

pub fn verify(game_dir: Option<PathBuf>) -> Result<(), String> {
    let game = engine::resolve_game_dir(game_dir.as_deref())?;
    let a = engine::assess(&game)?;
    println!("游戏目录: {}", game.display());
    println!(
        "补丁集: Keucher {} + DeltaruneChinese {}\n",
        a.keucher_version, a.chinese_commit
    );
    for s in &a.statuses {
        println!("  {:<28} {}", s.rel, s.state.label());
    }
    Ok(())
}

pub fn apply(
    game_dir: Option<PathBuf>,
    yes: bool,
    no_backup: bool,
    dry_run: bool,
) -> Result<(), String> {
    let game = engine::resolve_game_dir(game_dir.as_deref())?;
    let a = engine::assess(&game)?;
    println!("游戏目录: {}", game.display());
    println!(
        "补丁集: Keucher {} + DeltaruneChinese {}\n",
        a.keucher_version, a.chinese_commit
    );
    for s in &a.statuses {
        println!("  {:<28} {}", s.rel, s.state.label());
    }
    if !a.ready() {
        return Err(format!(
            "以下文件不是预期的纯净 vanilla(也不是已打补丁的结果),已中止:\n  {}\n\
             请先把游戏还原为未修改的正版:Steam 库中右键 DELTARUNE →「属性」→「已安装文件」→「验证游戏文件的完整性」,或确认游戏版本是否匹配。",
            a.blockers.join("\n  ")
        ));
    }
    if a.all_done() {
        println!("\n所有 data.win 已是合并版;继续确保 data_keucher.win 与 lang/vid 就位。");
    }

    if !yes && !dry_run {
        print!(
            "\n将修改 {} 下的 data.win 并铺放汉化资源{}。继续?[y/N] ",
            game.display(),
            if no_backup {
                "(不备份)"
            } else {
                "(会先备份原文件)"
            }
        );
        std::io::stdout().flush().ok();
        let mut line = String::new();
        std::io::stdin().read_line(&mut line).ok();
        if !matches!(line.trim(), "y" | "Y" | "yes") {
            return Err("用户取消".into());
        }
    }

    if dry_run {
        println!(
            "\n[dry-run] 计划打补丁 {} 个 data.win 并铺放外置资源。未写任何文件。",
            a.to_patch
        );
        return Ok(());
    }

    let mut cb = |p: Progress| match p {
        Progress::Backup => println!("  备份原文件…"),
        Progress::Patch { rel, index, total } => println!("  [{index}/{total}] {rel}"),
        Progress::Extras { count } => println!("  铺放 {count} 个 lang/vid 资源…"),
    };
    let rep = engine::apply(&game, ApplyOptions { backup: !no_backup }, &mut cb)?;

    println!("\n完成:DELTARUNE 已应用 Keucher+CHS 共存补丁。");
    if let Some(dir) = &rep.backup_dir {
        println!("备份: {}", dir.display());
        println!("还原: dr-tas-chs restore --game-dir \"{}\"", game.display());
    }
    Ok(())
}

pub fn restore(game_dir: Option<PathBuf>, backup: Option<PathBuf>) -> Result<(), String> {
    let game = engine::resolve_game_dir(game_dir.as_deref())?;
    let (dir, n) = engine::restore(&game, backup)?;
    println!(
        "已从 {} 恢复 {n} 个文件到 {}",
        dir.display(),
        game.display()
    );
    Ok(())
}
