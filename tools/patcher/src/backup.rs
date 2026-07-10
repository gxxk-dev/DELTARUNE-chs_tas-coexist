use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// 备份存放在游戏根下的这个子目录里,便于查找与回滚。
pub const BACKUP_ROOT: &str = "_dr_tas_chs_backup";
const ABSENT_PATHS_FILE: &str = ".absent_paths";
const ABSENT_DIRS_FILE: &str = ".absent_dirs";

/// 新建一次带时间戳的备份目录:<game>/_dr_tas_chs_backup/<epoch>/
pub fn new_backup_dir(game: &Path) -> std::io::Result<PathBuf> {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let root = game.join(BACKUP_ROOT);
    fs::create_dir_all(&root)?;
    for suffix in 0..1000 {
        let name = if suffix == 0 {
            ts.to_string()
        } else {
            format!("{ts}-{suffix}")
        };
        let dir = root.join(name);
        match fs::create_dir(&dir) {
            Ok(()) => return Ok(dir),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "unable to allocate a unique backup directory",
    ))
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

/// 记录安装前不存在、还原时应删除的相对文件及新建父目录。
pub fn record_absent(game: &Path, backup: &Path, rel: &str) -> std::io::Result<()> {
    let rel_path = validate_relative_path(rel)?;
    append_line(&backup.join(ABSENT_PATHS_FILE), rel)?;

    let mut parent = rel_path.parent();
    while let Some(dir) = parent.filter(|dir| !dir.as_os_str().is_empty()) {
        if game.join(dir).exists() {
            break;
        }
        append_line(&backup.join(ABSENT_DIRS_FILE), &dir.to_string_lossy())?;
        parent = dir.parent();
    }
    Ok(())
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
    remove_absent_paths(game, backup)?;
    Ok(n)
}

fn restore_walk(base: &Path, dir: &Path, game: &Path, n: &mut u64) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            restore_walk(base, &path, game, n)?;
        } else {
            let rel = path.strip_prefix(base).unwrap();
            if rel == Path::new(ABSENT_PATHS_FILE) || rel == Path::new(ABSENT_DIRS_FILE) {
                continue;
            }
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

fn remove_absent_paths(game: &Path, backup: &Path) -> std::io::Result<()> {
    let list = backup.join(ABSENT_PATHS_FILE);
    let Ok(content) = fs::read_to_string(list) else {
        return Ok(());
    };

    for rel in content.lines().filter(|line| !line.is_empty()) {
        let rel_path = validate_relative_path(rel)?;
        let path = game.join(rel_path);
        if path.is_file() || path.is_symlink() {
            fs::remove_file(path)?;
        }
    }

    let dirs = backup.join(ABSENT_DIRS_FILE);
    let Ok(content) = fs::read_to_string(dirs) else {
        return Ok(());
    };
    let mut paths: Vec<&str> = content.lines().filter(|line| !line.is_empty()).collect();
    paths.sort_by_key(|rel| std::cmp::Reverse(Path::new(rel).components().count()));
    paths.dedup();
    for rel in paths {
        let path = game.join(validate_relative_path(rel)?);
        match fs::remove_dir(path) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::DirectoryNotEmpty
                ) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn validate_relative_path(rel: &str) -> std::io::Result<&Path> {
    let path = Path::new(rel);
    if rel.is_empty()
        || path.is_absolute()
        || path
            .components()
            .any(|part| !matches!(part, std::path::Component::Normal(_)))
    {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("invalid backup path: {rel}"),
        ));
    }
    Ok(path)
}

fn append_line(path: &Path, value: &str) -> std::io::Result<()> {
    use std::io::Write;

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(file, "{value}")
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEST_DIR: AtomicU64 = AtomicU64::new(0);

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let sequence = NEXT_TEST_DIR.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "dr-tas-chs-backup-test-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn restore_removes_files_and_directories_created_by_install() {
        let root = TestDir::new();
        let game = root.0.join("game");
        let backup = root.0.join("backup");
        fs::create_dir_all(game.join("chapter1_windows")).unwrap();
        fs::create_dir_all(&backup).unwrap();

        let rel = "chapter1_windows/lang/lang_en.json";
        record_absent(&game, &backup, rel).unwrap();
        fs::create_dir_all(game.join("chapter1_windows/lang")).unwrap();
        fs::write(game.join(rel), b"installed").unwrap();

        assert_eq!(restore_from(&game, &backup).unwrap(), 0);
        assert!(!game.join(rel).exists());
        assert!(!game.join("chapter1_windows/lang").exists());
        assert!(game.join("chapter1_windows").is_dir());
    }

    #[test]
    fn restore_preserves_preexisting_file_content() {
        let root = TestDir::new();
        let game = root.0.join("game");
        let backup = root.0.join("backup");
        let rel = "vid/ch5_intro_en.mp4";
        fs::create_dir_all(game.join("vid")).unwrap();
        fs::create_dir_all(&backup).unwrap();
        fs::write(game.join(rel), b"original").unwrap();

        backup_rel(&game, &backup, rel).unwrap();
        fs::write(game.join(rel), b"installed").unwrap();

        assert_eq!(restore_from(&game, &backup).unwrap(), 1);
        assert_eq!(fs::read(game.join(rel)).unwrap(), b"original");
    }

    #[test]
    fn absent_path_rejects_parent_traversal() {
        let root = TestDir::new();
        let game = root.0.join("game");
        let backup = root.0.join("backup");
        fs::create_dir_all(&game).unwrap();
        fs::create_dir_all(&backup).unwrap();

        assert!(record_absent(&game, &backup, "../outside").is_err());
    }

    #[test]
    fn backup_directories_are_unique() {
        let root = TestDir::new();
        let first = new_backup_dir(&root.0).unwrap();
        let second = new_backup_dir(&root.0).unwrap();

        assert_ne!(first, second);
        assert!(first.is_dir());
        assert!(second.is_dir());
    }
}
