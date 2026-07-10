// 打补丁核心引擎:被 CLI 和 GUI 共用。不做任何 println,只返回结构化结果或通过进度回调上报,
// 便于 GUI 在后台线程调用并渲染。
use crate::assets;
use crate::backup;
use crate::gamedir;
use crate::manifest::{Manifest, Target};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// 一个目标文件相对内嵌数据的当前状态。
#[derive(Clone)]
pub enum State {
    /// 与 vanilla 源哈希一致,可打补丁
    NeedsPatch,
    /// 已经是合并结果哈希,无需再打
    AlreadyDone,
    /// 文件缺失
    Missing,
    /// 哈希对不上任何已知值(非纯净安装 / 游戏版本不符)
    Unknown(String),
}

impl State {
    pub fn label(&self) -> String {
        match self {
            State::NeedsPatch => "vanilla(待打补丁)".into(),
            State::AlreadyDone => "已是 Keucher+CHS 合并版".into(),
            State::Missing => "缺失!".into(),
            State::Unknown(s) => format!(
                "未知内容,sha256={}…(非纯净或版本不符)",
                &s[..12.min(s.len())]
            ),
        }
    }
    pub fn is_blocker(&self) -> bool {
        matches!(self, State::Missing | State::Unknown(_))
    }
    pub fn needs_patch(&self) -> bool {
        matches!(self, State::NeedsPatch)
    }
}

pub struct FileStatus {
    pub rel: String,
    pub state: State,
}

/// 对游戏目录的整体评估结果。
pub struct Assessment {
    pub keucher_version: String,
    pub chinese_commit: String,
    pub statuses: Vec<FileStatus>,
    pub to_patch: usize,
    pub blockers: Vec<String>,
}

impl Assessment {
    pub fn ready(&self) -> bool {
        self.blockers.is_empty()
    }
    pub fn all_done(&self) -> bool {
        self.blockers.is_empty() && self.to_patch == 0
    }
}

/// 打补丁过程中的进度事件。
pub enum Progress {
    Backup,
    Patch {
        rel: String,
        index: usize,
        total: usize,
    },
    Extras {
        count: usize,
    },
}

#[derive(Clone, Copy)]
pub struct ApplyOptions {
    pub backup: bool,
}

pub struct ApplyReport {
    pub patched: usize,
    pub backup_dir: Option<PathBuf>,
}

pub fn load_manifest() -> Result<Manifest, String> {
    let bytes =
        assets::get("manifest.json").ok_or("内嵌 manifest.json 缺失(构建时未生成 assets)")?;
    Manifest::parse(&bytes)
}

fn evaluate(game: &Path, t: &Target) -> std::io::Result<State> {
    let path = game.join(&t.rel);
    if !path.is_file() {
        return Ok(State::Missing);
    }
    let sha = sha256_file(&path)?;
    Ok(if sha == t.src_sha256 {
        State::NeedsPatch
    } else if sha == t.dst_sha256 {
        State::AlreadyDone
    } else {
        State::Unknown(sha)
    })
}

pub fn assess(game: &Path) -> Result<Assessment, String> {
    let m = load_manifest()?;
    let mut statuses = Vec::new();
    let mut to_patch = 0;
    let mut blockers = Vec::new();
    for t in &m.targets {
        let state = evaluate(game, t).map_err(|e| format!("读取 {} 失败: {e}", t.rel))?;
        if state.needs_patch() {
            to_patch += 1;
        }
        if state.is_blocker() {
            blockers.push(t.rel.clone());
        }
        statuses.push(FileStatus {
            rel: t.rel.clone(),
            state,
        });
    }
    Ok(Assessment {
        keucher_version: m.keucher_mod_version,
        chinese_commit: m.deltarune_chinese_commit,
        statuses,
        to_patch,
        blockers,
    })
}

/// 应用补丁。progress 回调用于上报进度(CLI 打印 / GUI 更新界面)。
pub fn apply(
    game: &Path,
    opts: ApplyOptions,
    progress: &mut dyn FnMut(Progress),
) -> Result<ApplyReport, String> {
    let m = load_manifest()?;

    // 预检
    let mut states = Vec::new();
    let mut to_patch = 0;
    let mut blockers = Vec::new();
    for t in &m.targets {
        let s = evaluate(game, t).map_err(|e| format!("读取 {} 失败: {e}", t.rel))?;
        if s.needs_patch() {
            to_patch += 1;
        }
        if s.is_blocker() {
            blockers.push(t.rel.clone());
        }
        states.push(s);
    }
    if !blockers.is_empty() {
        return Err(format!(
            "以下文件不是预期的纯净 vanilla(也不是已打补丁的结果),已中止,未改动任何文件:\n  {}\n\
             请先把游戏还原为未修改的正版:Steam 库中右键 DELTARUNE →「属性」→「已安装文件」→「验证游戏文件的完整性」,或确认游戏版本与本补丁集匹配。",
            blockers.join("\n  ")
        ));
    }

    let mut keucher_changes = Vec::with_capacity(m.targets.len());
    for t in &m.targets {
        let needs_write = if t.data_keucher_win {
            let rel = Manifest::data_keucher_path(&t.rel)
                .ok_or_else(|| format!("无法生成 data_keucher.win 路径: {}", t.rel))?;
            !file_matches_sha256(&game.join(rel), &t.dst_sha256)
                .map_err(|e| format!("读取 {} 的 data_keucher.win 失败: {e}", t.rel))?
        } else {
            false
        };
        keucher_changes.push(needs_write);
    }

    let mut extra_changes = Vec::with_capacity(m.extras.len());
    for ex in &m.extras {
        let bytes = assets::get(&ex.asset).ok_or_else(|| format!("内嵌资源缺失: {}", ex.asset))?;
        let needs_write = !file_matches_bytes(&game.join(&ex.rel), &bytes)
            .map_err(|e| format!("读取 {} 失败: {e}", ex.rel))?;
        extra_changes.push(needs_write);
    }

    let has_changes = to_patch > 0
        || keucher_changes.iter().any(|needs_write| *needs_write)
        || extra_changes.iter().any(|needs_write| *needs_write);

    // 备份:仅当确有文件需要改动时才建;幂等重跑不备份也不覆盖 latest 指针。
    let backup_dir = if !opts.backup || !has_changes {
        None
    } else {
        progress(Progress::Backup);
        let dir = backup::new_backup_dir(game).map_err(|e| format!("创建备份目录失败: {e}"))?;
        for (index, (t, state)) in m.targets.iter().zip(states.iter()).enumerate() {
            if state.needs_patch() {
                backup::backup_rel(game, &dir, &t.rel)
                    .map_err(|e| format!("备份 {} 失败: {e}", t.rel))?;
            }
            if t.data_keucher_win && keucher_changes[index] {
                let kw = Manifest::data_keucher_path(&t.rel)
                    .ok_or_else(|| format!("无法生成 data_keucher.win 路径: {}", t.rel))?;
                backup_or_record_absent(game, &dir, &kw)?;
            }
        }
        for (ex, needs_write) in m.extras.iter().zip(extra_changes.iter()) {
            if *needs_write {
                backup_or_record_absent(game, &dir, &ex.rel)?;
            }
        }
        backup::record_latest(game, &dir).map_err(|e| format!("记录最新备份失败: {e}"))?;
        Some(dir)
    };

    // 打补丁
    let total = m.targets.len();
    for (i, ((t, state), needs_keucher_write)) in m
        .targets
        .iter()
        .zip(states.iter())
        .zip(keucher_changes.iter())
        .enumerate()
    {
        progress(Progress::Patch {
            rel: t.rel.clone(),
            index: i + 1,
            total,
        });
        let target_path = game.join(&t.rel);
        let final_bytes: Vec<u8> = match state {
            State::NeedsPatch => {
                let src =
                    fs::read(&target_path).map_err(|e| format!("读取 {} 失败: {e}", t.rel))?;
                let patch =
                    assets::get(&t.patch).ok_or_else(|| format!("内嵌补丁缺失: {}", t.patch))?;
                let out = xdelta3::decode(&patch, &src)
                    .ok_or_else(|| format!("{}: xdelta3 解码失败", t.rel))?;
                let got = sha256_bytes(&out);
                if got != t.dst_sha256 {
                    return Err(format!(
                        "{}: 打补丁后哈希不符(期望 {}… 实得 {}…),已中止。{}",
                        t.rel,
                        &t.dst_sha256[..12],
                        &got[..12],
                        backup_dir
                            .as_deref()
                            .map(|p| format!("原文件已备份在 {}", p.display()))
                            .unwrap_or_default()
                    ));
                }
                write_atomic(&target_path, &out)
                    .map_err(|e| format!("写入 {} 失败: {e}", t.rel))?;
                out
            }
            State::AlreadyDone => {
                fs::read(&target_path).map_err(|e| format!("读取 {} 失败: {e}", t.rel))?
            }
            _ => unreachable!("blocker 已在预检拦截"),
        };

        if t.data_keucher_win {
            if let Some(kw) = Manifest::data_keucher_path(&t.rel) {
                let kw_path = game.join(&kw);
                if *needs_keucher_write {
                    write_atomic(&kw_path, &final_bytes)
                        .map_err(|e| format!("写入 {kw} 失败: {e}"))?;
                }
            }
        }
    }

    // 外置资源(lang/ 文本、vid/ 视频、mus/ 音频)
    let extras_to_write = extra_changes
        .iter()
        .filter(|needs_write| **needs_write)
        .count();
    if extras_to_write > 0 {
        progress(Progress::Extras {
            count: extras_to_write,
        });
        for (ex, needs_write) in m.extras.iter().zip(extra_changes.iter()) {
            if !needs_write {
                continue;
            }
            let bytes =
                assets::get(&ex.asset).ok_or_else(|| format!("内嵌资源缺失: {}", ex.asset))?;
            write_atomic(&game.join(&ex.rel), &bytes)
                .map_err(|e| format!("写入 {} 失败: {e}", ex.rel))?;
        }
    }

    Ok(ApplyReport {
        patched: to_patch,
        backup_dir,
    })
}

fn backup_or_record_absent(game: &Path, backup_dir: &Path, rel: &str) -> Result<(), String> {
    if game.join(rel).exists() {
        backup::backup_rel(game, backup_dir, rel).map_err(|e| format!("备份 {rel} 失败: {e}"))
    } else {
        backup::record_absent(game, backup_dir, rel)
            .map_err(|e| format!("记录待清理路径 {rel} 失败: {e}"))
    }
}

fn file_matches_sha256(path: &Path, expected: &str) -> std::io::Result<bool> {
    match sha256_file(path) {
        Ok(actual) => Ok(actual == expected),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn file_matches_bytes(path: &Path, expected: &[u8]) -> std::io::Result<bool> {
    match fs::read(path) {
        Ok(actual) => Ok(actual == expected),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

pub fn restore(game: &Path, backup_dir: Option<PathBuf>) -> Result<(PathBuf, u64), String> {
    let dir = match backup_dir {
        Some(p) => p,
        None => backup::latest(game).ok_or("找不到备份记录(latest.txt),请手动指定备份目录")?,
    };
    if !dir.is_dir() {
        return Err(format!("备份目录不存在: {}", dir.display()));
    }
    let n = backup::restore_from(game, &dir).map_err(|e| format!("回滚失败: {e}"))?;
    Ok((dir, n))
}

/// 是否存在可用于还原的备份记录。
pub fn has_backup(game: &Path) -> bool {
    backup::latest(game).map(|p| p.is_dir()).unwrap_or(false)
}

/// 解析游戏目录:显式路径 > DELTARUNE_GAME_DIR > 自动探测。
pub fn resolve_game_dir(explicit: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(p) = explicit {
        return if gamedir::looks_like_deltarune(p) {
            Ok(p.to_path_buf())
        } else {
            Err(format!(
                "{} 不像 DELTARUNE 安装目录(缺 data.win 或章节)",
                p.display()
            ))
        };
    }
    if let Ok(env) = std::env::var("DELTARUNE_GAME_DIR") {
        let p = PathBuf::from(&env);
        return if gamedir::looks_like_deltarune(&p) {
            Ok(p)
        } else {
            Err(format!("DELTARUNE_GAME_DIR={env} 不像 DELTARUNE 安装目录"))
        };
    }
    let found = gamedir::autodetect();
    match found.len() {
        0 => Err("未能自动定位 DELTARUNE,请指定安装目录".into()),
        1 => Ok(found.into_iter().next().unwrap()),
        _ => {
            let list = found
                .iter()
                .map(|p| format!("  {}", p.display()))
                .collect::<Vec<_>>()
                .join("\n");
            Err(format!("找到多个 DELTARUNE 安装,请指定其一:\n{list}"))
        }
    }
}

pub fn sha256_file(p: &Path) -> std::io::Result<String> {
    Ok(sha256_bytes(&fs::read(p)?))
}

pub fn sha256_bytes(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

/// 原子写:先写临时文件再 rename。
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("drtcs_tmp");
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}
