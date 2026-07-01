// 构建期:递归遍历 assets/ 目录,为其中每个文件生成一条 include_bytes! 记录,
// 汇总成 ASSETS 表(键为相对 assets/ 的路径,值为文件字节)。
// 若 assets/ 或 manifest.json 缺失,则给出明确指引后失败——因为这是一个数据自带型二进制。
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let assets_dir = Path::new(&manifest_dir).join("assets");
    println!("cargo:rerun-if-changed=assets");

    if !assets_dir.join("manifest.json").is_file() {
        panic!(
            "missing {}/assets/manifest.json.\n\
             Generate embedded assets first:\n\
             \x20 DELTARUNE_GAME_DIR=/path/to/vanilla ./scripts/gen_assets.sh",
            manifest_dir
        );
    }

    let mut files: Vec<PathBuf> = Vec::new();
    collect(&assets_dir, &mut files);
    files.sort();

    let mut code = String::from("pub static ASSETS: &[(&str, &[u8])] = &[\n");
    for f in &files {
        let rel = f
            .strip_prefix(&assets_dir)
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        let abs = f.to_string_lossy().replace('\\', "/");
        writeln!(code, "    ({rel:?}, include_bytes!({abs:?})),").unwrap();
    }
    code.push_str("];\n");

    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("assets_embed.rs");
    fs::write(&out, code).unwrap();
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect(&path, out);
        } else {
            out.push(path);
        }
    }
}
