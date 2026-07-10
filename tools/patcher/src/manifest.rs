use serde::Deserialize;

/// 内嵌 manifest.json 的结构。由 scripts/gen_assets.sh 生成。
#[derive(Debug, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub keucher_mod_version: String,
    #[serde(default)]
    pub deltarune_chinese_commit: String,
    pub targets: Vec<Target>,
    #[serde(default)]
    pub extras: Vec<Extra>,
}

/// 一个需要打补丁的 data.win 目标。
#[derive(Debug, Deserialize)]
pub struct Target {
    #[allow(dead_code)]
    pub id: String,
    /// 相对游戏根目录的路径,如 `chapter1_windows/data.win`。
    pub rel: String,
    /// 相对 assets/ 的 xdelta 补丁路径。
    pub patch: String,
    /// 纯 vanilla 源文件的 sha256(打补丁前应匹配)。
    pub src_sha256: String,
    /// 合并结果的 sha256(打补丁后应匹配)。
    pub dst_sha256: String,
    /// 该章节是否还需把结果同时写成 data_keucher.win(Keucher 章节选择会读它)。
    #[serde(default)]
    pub data_keucher_win: bool,
}

/// 直接铺放的外置资源(CHS 的 lang/ 文本、vid/ 视频、mus/ 音频)。
#[derive(Debug, Deserialize)]
pub struct Extra {
    /// 相对 assets/ 的资源路径。
    pub asset: String,
    /// 相对游戏根目录的目标路径。
    pub rel: String,
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        serde_json::from_slice(bytes).map_err(|e| format!("invalid manifest.json: {e}"))
    }

    pub fn data_keucher_path(rel: &str) -> Option<String> {
        // chapterN_windows/data.win -> chapterN_windows/data_keucher.win
        rel.strip_suffix("data.win")
            .map(|dir| format!("{dir}data_keucher.win"))
    }
}
