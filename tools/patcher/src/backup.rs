use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// 备份存放在游戏根下的这个子目录里,便于查找与回滚。
pub const BACKUP_ROOT: &str = "_dr_tas_chs_backup";

/// 新建一次带时间戳的备份目录:<game>/_dr_tas_chs_backup/<epoch>/
pub fn new_backup_dir(game: &Path) -> std::io::Result<PathBuf> {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dir = game.join(BACKUP_ROOT).join(ts.to_string());
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// 备份游戏根下的一个相对路径(文件或目录,若存在),保留目录结构。
pub fn backup_rel(game: &Path, backup: &Path, rel: &str) -> std::io::Result<()> {
    let src = game.join(rel);
    if !src.exists() {
        return Ok(());
    }
    let dst = backup.join(rel);
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    if src.is_dir() {
        copy_dir(&src, &dst)
    } else {
        fs::copy(&src, &dst).map(|_| ())
    }
}

/// 记录最近一次备份目录,供 restore 默认使用。
pub fn record_latest(game: &Path, backup: &Path) -> std::io::Result<()> {
    fs::write(
        game.join(BACKUP_ROOT).join("latest.txt"),
        backup.to_string_lossy().as_bytes(),
    )
}

/// 读取最近一次备份目录。
pub fn latest(game: &Path) -> Option<PathBuf> {
    let s = fs::read_to_string(game.join(BACKUP_ROOT).join("latest.txt")).ok()?;
    let s = s.trim();
    if s.is_empty() {
        None
    } else {
        Some(PathBuf::from(s))
    }
}

/// 把某个备份目录里的所有文件按相对路径拷回游戏根,返回恢复的文件数。
pub fn restore_from(game: &Path, backup: &Path) -> std::io::Result<u64> {
    let mut n = 0;
    restore_walk(backup, backup, game, &mut n)?;
    Ok(n)
}

fn restore_walk(base: &Path, dir: &Path, game: &Path, n: &mut u64) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            restore_walk(base, &path, game, n)?;
        } else {
            let rel = path.strip_prefix(base).unwrap();
            // 跳过 latest.txt 之类的元数据(它直接躺在 BACKUP_ROOT 下,不在具体备份里)
            let dst = game.join(rel);
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&path, &dst)?;
            *n += 1;
        }
    }
    Ok(())
}

fn copy_dir(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let from = entry.path();
        let to = dst.join(entry.file_name());
        if from.is_dir() {
            copy_dir(&from, &to)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}
