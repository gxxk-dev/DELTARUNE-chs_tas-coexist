use std::path::{Path, PathBuf};

/// 校验一个目录是否像 DELTARUNE 安装根(含 data.win 与 chapter1-5 的 data.win)。
pub fn looks_like_deltarune(dir: &Path) -> bool {
    if !dir.join("data.win").is_file() {
        return false;
    }
    (1..=5).all(|c| {
        dir.join(format!("chapter{c}_windows"))
            .join("data.win")
            .is_file()
    })
}

/// 按平台推测候选 DELTARUNE 安装目录(扫描 Steam 默认库 + libraryfolders.vdf)。
pub fn autodetect() -> Vec<PathBuf> {
    let mut steam_roots: Vec<PathBuf> = Vec::new();

    #[cfg(target_os = "windows")]
    {
        for env in ["ProgramFiles(x86)", "ProgramFiles"] {
            if let Ok(p) = std::env::var(env) {
                steam_roots.push(PathBuf::from(p).join("Steam"));
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = home_dir() {
            steam_roots.push(home.join("Library/Application Support/Steam"));
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(home) = home_dir() {
            steam_roots.push(home.join(".steam/steam"));
            steam_roots.push(home.join(".local/share/Steam"));
            steam_roots.push(home.join(".var/app/com.valvesoftware.Steam/data/Steam"));
        }
    }

    // 每个 steam 根既是一个库,也可能通过 libraryfolders.vdf 指向别处的库
    let mut libraries: Vec<PathBuf> = Vec::new();
    for root in &steam_roots {
        libraries.push(root.clone());
        let vdf = root.join("steamapps/libraryfolders.vdf");
        if let Ok(text) = std::fs::read_to_string(&vdf) {
            libraries.extend(parse_library_paths(&text));
        }
    }

    let mut found: Vec<PathBuf> = Vec::new();
    for lib in libraries {
        let candidate = lib.join("steamapps/common/DELTARUNE");
        if looks_like_deltarune(&candidate) && !found.contains(&candidate) {
            found.push(candidate);
        }
    }
    found
}

/// 从 libraryfolders.vdf 粗略抽取所有 `"path" "..."` 值。
fn parse_library_paths(text: &str) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("\"path\"") {
            if let Some(start) = rest.find('"') {
                let rest = &rest[start + 1..];
                if let Some(end) = rest.find('"') {
                    out.push(PathBuf::from(rest[..end].replace("\\\\", "\\")));
                }
            }
        }
    }
    out
}

#[allow(dead_code)]
fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("USERPROFILE").map(PathBuf::from))
}
