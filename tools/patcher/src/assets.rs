// 由 build.rs 在 OUT_DIR 生成:pub static ASSETS: &[(&str, &[u8])]
// 键是相对 assets/ 的路径,如 "manifest.json"、"patches/ch1.xdelta"、"fonts/ui.ttf"。
// 体积较大的文本/视频以 `<name>.zst` 形式内嵌(打包期 zstd -19),运行时按需解压。
use std::borrow::Cow;

include!(concat!(env!("OUT_DIR"), "/assets_embed.rs"));

fn raw(name: &str) -> Option<&'static [u8]> {
    ASSETS.iter().find(|(k, _)| *k == name).map(|(_, v)| *v)
}

/// 按相对路径取内嵌资源字节。若不存在裸文件但存在 `<name>.zst`,则解压后返回。
pub fn get(name: &str) -> Option<Cow<'static, [u8]>> {
    if let Some(b) = raw(name) {
        return Some(Cow::Borrowed(b));
    }
    let zst = format!("{name}.zst");
    raw(&zst).map(|b| Cow::Owned(zstd_decode(b)))
}

/// 仅取未压缩的裸资源(用于需要 &'static 的场景,如字体)。
pub fn get_static(name: &str) -> Option<&'static [u8]> {
    raw(name)
}

fn zstd_decode(data: &[u8]) -> Vec<u8> {
    use std::io::Read;
    let mut dec =
        ruzstd::StreamingDecoder::new(data).expect("内嵌资源不是合法的 zstd 帧");
    let mut out = Vec::new();
    dec.read_to_end(&mut out).expect("解压内嵌资源失败");
    out
}
