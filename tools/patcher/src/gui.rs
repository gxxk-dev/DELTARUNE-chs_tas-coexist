// 图形安装器(eframe/egui)。核心逻辑全在 engine,这里只负责界面与在后台线程调用 engine。
// 视觉走简洁近单色暗色:中性灰阶 + 极少强调色,状态用朴素小字,主按钮用浅色 CTA。
use crate::assets;
use crate::engine::{self, ApplyOptions, Assessment, Progress, State};
use eframe::egui::{self, Color32, CornerRadius, Margin, RichText, Stroke};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver};

// —— 简洁中性调色板 ——
const CANVAS: Color32 = Color32::from_rgb(26, 26, 30);
const WELL: Color32 = Color32::from_rgb(33, 33, 39);
const CARD: Color32 = Color32::from_rgb(43, 43, 50); // 次级按钮默认态
const CARD_HOVER: Color32 = Color32::from_rgb(54, 54, 62);
const TEXT: Color32 = Color32::from_rgb(233, 233, 238);
const MUTED: Color32 = Color32::from_rgb(140, 140, 149);
const BORDER: Color32 = Color32::from_rgb(46, 46, 54);
const BORDER_STRONG: Color32 = Color32::from_rgb(66, 66, 76);
const PRIMARY: Color32 = Color32::from_rgb(236, 236, 240); // 主按钮浅色
const ON_PRIMARY: Color32 = Color32::from_rgb(24, 24, 28);
const OK: Color32 = Color32::from_rgb(126, 184, 150);
const DANGER: Color32 = Color32::from_rgb(210, 136, 136);
const PROGRESS: Color32 = Color32::from_rgb(150, 150, 160);

pub fn run() -> Result<(), String> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([460.0, 468.0])
            .with_min_inner_size([420.0, 380.0])
            .with_title("DELTARUNE Keucher+CHS 安装器"),
        ..Default::default()
    };
    eframe::run_native(
        "DELTARUNE Keucher+CHS 安装器",
        options,
        Box::new(|cc| {
            setup_style(&cc.egui_ctx);
            Ok(Box::new(App::new(cc)))
        }),
    )
    .map_err(|e| e.to_string())
}

fn setup_style(ctx: &egui::Context) {
    // 字体:内嵌 HarmonyOS Sans SC,补上 egui 默认字体缺的中文。
    if let Some(bytes) = assets::get_static("fonts/ui.ttf") {
        let mut fonts = egui::FontDefinitions::default();
        fonts.font_data.insert(
            "ui".to_owned(),
            std::sync::Arc::new(egui::FontData::from_static(bytes)),
        );
        fonts
            .families
            .entry(egui::FontFamily::Proportional)
            .or_default()
            .insert(0, "ui".to_owned());
        fonts
            .families
            .entry(egui::FontFamily::Monospace)
            .or_default()
            .insert(0, "ui".to_owned());
        ctx.set_fonts(fonts);
    }

    ctx.set_theme(egui::ThemePreference::Dark);
    ctx.all_styles_mut(|style| {
        use egui::{FontFamily, FontId, TextStyle};
        let v = &mut style.visuals;
        v.dark_mode = true;
        v.override_text_color = Some(TEXT);
        v.panel_fill = CANVAS;
        v.window_fill = CANVAS;
        v.window_stroke = Stroke::new(1.0, BORDER);
        v.extreme_bg_color = WELL;
        v.faint_bg_color = WELL;
        v.hyperlink_color = MUTED;
        v.selection.bg_fill = PROGRESS; // 进度条填充 / 文本选中
        v.selection.stroke = Stroke::new(1.0, TEXT);

        let radius = CornerRadius::same(6);
        for w in [
            &mut v.widgets.noninteractive,
            &mut v.widgets.inactive,
            &mut v.widgets.hovered,
            &mut v.widgets.active,
            &mut v.widgets.open,
        ] {
            w.corner_radius = radius;
            w.fg_stroke = Stroke::new(1.0, TEXT);
            w.bg_stroke = Stroke::new(1.0, BORDER);
        }
        v.widgets.noninteractive.bg_fill = CANVAS;
        v.widgets.noninteractive.weak_bg_fill = CANVAS;
        v.widgets.noninteractive.fg_stroke = Stroke::new(1.0, MUTED);
        v.widgets.inactive.bg_fill = CARD;
        v.widgets.inactive.weak_bg_fill = CARD;
        v.widgets.hovered.bg_fill = CARD_HOVER;
        v.widgets.hovered.weak_bg_fill = CARD_HOVER;
        v.widgets.hovered.bg_stroke = Stroke::new(1.0, BORDER_STRONG);
        v.widgets.active.bg_fill = CARD_HOVER;
        v.widgets.active.weak_bg_fill = CARD_HOVER;
        v.widgets.active.bg_stroke = Stroke::new(1.0, BORDER_STRONG);

        style.spacing.item_spacing = egui::vec2(6.0, 4.0);
        style.spacing.button_padding = egui::vec2(10.0, 5.0);
        style.spacing.interact_size.y = 26.0;

        let prop = FontFamily::Proportional;
        style.text_styles = [
            (TextStyle::Heading, FontId::new(21.0, prop.clone())),
            (TextStyle::Body, FontId::new(15.0, prop.clone())),
            (TextStyle::Button, FontId::new(15.0, prop.clone())),
            (TextStyle::Small, FontId::new(12.5, prop.clone())),
            (
                TextStyle::Monospace,
                FontId::new(13.5, FontFamily::Monospace),
            ),
        ]
        .into();
    });
}

/// 圆角凹陷面板(well),用于分组次要内容。
fn well<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::default()
        .fill(WELL)
        .stroke(Stroke::new(1.0, BORDER))
        .corner_radius(CornerRadius::same(8))
        .inner_margin(Margin::same(9))
        .show(ui, add)
        .inner
}

fn state_text(state: &State) -> (&'static str, Color32) {
    match state {
        State::NeedsPatch => ("待安装", MUTED),
        State::AlreadyDone => ("已安装", OK),
        State::Missing => ("缺失", DANGER),
        State::Unknown(_) => ("版本不符", DANGER),
    }
}

enum Msg {
    Log(String),
    Progress(f32),
    Done(Result<String, String>),
}

struct App {
    ctx: egui::Context,
    game: Option<PathBuf>,
    game_input: String,
    assessment: Option<Result<Assessment, String>>,
    has_backup: bool,
    backup: bool,
    running: bool,
    rx: Option<Receiver<Msg>>,
    log: Vec<String>,
    progress: f32,
    final_msg: Option<Result<String, String>>,
    assessing: bool,
    assess_rx: Option<Receiver<(Result<Assessment, String>, bool)>>,
    /// 内嵌补丁集版本标注(Keucher 版本 + CHS commit),启动时从 manifest 读一次。
    built_in: String,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let built_in = engine::load_manifest()
            .ok()
            .map(|m| {
                let c = &m.deltarune_chinese_commit;
                let short = &c[..c.len().min(7)];
                format!(
                    "内置补丁 · Keucher {} · CHS {}",
                    m.keucher_mod_version, short
                )
            })
            .unwrap_or_default();
        let mut app = App {
            ctx: cc.egui_ctx.clone(),
            game: None,
            game_input: String::new(),
            assessment: None,
            has_backup: false,
            backup: true,
            running: false,
            rx: None,
            log: Vec::new(),
            progress: 0.0,
            final_msg: None,
            assessing: false,
            assess_rx: None,
            built_in,
        };
        if let Ok(p) = engine::resolve_game_dir(None) {
            app.game_input = p.display().to_string();
            app.game = Some(p);
            app.start_assess();
        }
        app
    }

    /// 在后台线程评估当前游戏目录(读取全部 data.win 做哈希较耗时,放线程避免卡界面)。
    fn start_assess(&mut self) {
        let Some(g) = self.game.clone() else {
            self.assessment = None;
            self.assessing = false;
            return;
        };
        let ctx = self.ctx.clone();
        let (tx, rx) = channel();
        self.assess_rx = Some(rx);
        self.assessing = true;
        std::thread::spawn(move || {
            let result = (engine::assess(&g), engine::has_backup(&g));
            let _ = tx.send(result);
            ctx.request_repaint();
        });
    }

    fn set_game_from_input(&mut self) {
        let p = PathBuf::from(self.game_input.trim());
        match engine::resolve_game_dir(Some(&p)) {
            Ok(g) => {
                self.game = Some(g);
                self.final_msg = None;
                self.start_assess();
            }
            Err(e) => {
                self.game = None;
                self.assessment = Some(Err(e));
                self.has_backup = false;
            }
        }
    }

    fn start_apply(&mut self) {
        let Some(game) = self.game.clone() else {
            return;
        };
        let backup = self.backup;
        let ctx = self.ctx.clone();
        let (tx, rx) = channel();
        self.rx = Some(rx);
        self.running = true;
        self.progress = 0.0;
        self.log.clear();
        self.final_msg = None;

        std::thread::spawn(move || {
            let total = 6.0 + 1.0 + if backup { 1.0 } else { 0.0 };
            let mut done = 0.0f32;
            let mut cb = |p: Progress| {
                let line = match &p {
                    Progress::Backup => "备份原文件…".to_string(),
                    Progress::Patch { rel, index, total } => {
                        format!("[{index}/{total}] 打补丁 {rel}")
                    }
                    Progress::Extras { count } => format!("铺放 {count} 个 lang/vid/mus 资源…"),
                };
                done += 1.0;
                let _ = tx.send(Msg::Progress((done / total).min(0.99)));
                let _ = tx.send(Msg::Log(line));
                ctx.request_repaint();
            };
            let result = engine::apply(&game, ApplyOptions { backup }, &mut cb).map(|rep| {
                let mut message = if rep.patched == 0 {
                    "已是最新:所有文件均为 Keucher+CHS 合并版,已确保资源就位。".to_string()
                } else {
                    format!(
                        "完成:已对 {} 个 data.win 应用补丁并铺放汉化资源。",
                        rep.patched
                    )
                };
                if let Some(dir) = &rep.backup_dir {
                    message.push_str(&format!("\n原文件已备份到:{}", dir.display()));
                }
                message
            });
            let _ = tx.send(Msg::Progress(1.0));
            let _ = tx.send(Msg::Done(result));
            ctx.request_repaint();
        });
    }

    fn start_restore(&mut self) {
        let Some(game) = self.game.clone() else {
            return;
        };
        let ctx = self.ctx.clone();
        let (tx, rx) = channel();
        self.rx = Some(rx);
        self.running = true;
        self.progress = 0.0;
        self.log.clear();
        self.final_msg = None;
        std::thread::spawn(move || {
            let _ = tx.send(Msg::Log("正在从备份还原…".into()));
            ctx.request_repaint();
            let result = engine::restore(&game, None)
                .map(|(dir, n)| format!("已还原 {n} 个文件(来自 {})。", dir.display()));
            let _ = tx.send(Msg::Progress(1.0));
            let _ = tx.send(Msg::Done(result));
            ctx.request_repaint();
        });
    }

    fn drain(&mut self) {
        let mut done = false;
        if let Some(rx) = &self.rx {
            while let Ok(msg) = rx.try_recv() {
                match msg {
                    Msg::Log(l) => self.log.push(l),
                    Msg::Progress(p) => self.progress = p,
                    Msg::Done(r) => {
                        self.final_msg = Some(r);
                        done = true;
                    }
                }
            }
        }
        if done {
            self.running = false;
            self.rx = None;
            self.start_assess();
        }

        if let Some(rx) = &self.assess_rx {
            if let Ok((a, hb)) = rx.try_recv() {
                self.assessment = Some(a);
                self.has_backup = hb;
                self.assessing = false;
                self.assess_rx = None;
            }
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.drain();

        let mut act_use = false;
        let mut act_browse = false;
        let mut act_apply = false;
        let mut act_restore = false;
        let mut act_recheck = false;

        let can_install = !self.running
            && !self.assessing
            && matches!(&self.assessment, Some(Ok(a)) if a.ready());
        let install_label = match &self.assessment {
            Some(Ok(a)) if a.all_done() => "重新安装 / 修复",
            _ => "安装",
        };

        egui::CentralPanel::default().show(ui, |ui| {
            egui::ScrollArea::vertical()
                .auto_shrink([false, false])
                .show(ui, |ui| {
                    ui.add_space(2.0);
                    ui.heading("DELTARUNE Keucher × CHS 安装器");
                    ui.label(
                        RichText::new("为纯净正版一键安装 Keucher Mod 与中文(CHS)共存补丁。").color(MUTED),
                    );
                    if !self.built_in.is_empty() {
                        ui.add_space(2.0);
                        ui.label(RichText::new(&self.built_in).size(11.5).color(MUTED));
                    }
                    ui.add_space(6.0);

                    // —— 游戏目录 ——
                    ui.label(RichText::new("游戏目录").size(12.5).color(MUTED));
                    ui.add_space(2.0);
                    ui.horizontal(|ui| {
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            act_browse =
                                ui.add_enabled(!self.running, egui::Button::new("浏览…")).clicked();
                            let resp = ui.add_enabled(
                                !self.running,
                                egui::TextEdit::singleline(&mut self.game_input)
                                    .desired_width(ui.available_width())
                                    .hint_text("选择 DELTARUNE 安装目录…"),
                            );
                            if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                                act_use = true;
                            }
                        });
                    });
                    ui.add_space(6.0);

                    // —— 状态 ——
                    if self.assessing {
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.colored_label(MUTED, "检测中…");
                        });
                    } else {
                    match &self.assessment {
                        None => {
                            ui.colored_label(MUTED, "请选择 DELTARUNE 安装目录。");
                        }
                        Some(Err(e)) => {
                            well(ui, |ui| {
                                ui.colored_label(DANGER, e);
                            });
                        }
                        Some(Ok(a)) => {
                            well(ui, |ui| {
                                for s in &a.statuses {
                                    ui.horizontal(|ui| {
                                        ui.label(RichText::new(&s.rel).monospace().color(MUTED));
                                        ui.with_layout(
                                            egui::Layout::right_to_left(egui::Align::Center),
                                            |ui| {
                                                let (text, color) = state_text(&s.state);
                                                ui.label(RichText::new(text).size(13.0).color(color));
                                            },
                                        );
                                    });
                                }
                            });
                            ui.add_space(6.0);
                            if !a.ready() {
                                ui.colored_label(
                                    DANGER,
                                    "检测到文件不是纯净原版,无法直接安装。\n常见原因:① 已装过汉化组或 Keucher 单体版;② 游戏更新到了新版本(本补丁集只适配特定版本)。\n请先在 Steam 还原原版:库中右键 DELTARUNE →「属性」→「已安装文件」→「验证游戏文件的完整性」;完成后点「重新检测」。若确认已是纯净原版仍报此错,则你的游戏版本比补丁集新,请等待适配版。",
                                );
                            } else if a.all_done() {
                                ui.colored_label(OK, "已安装:所有文件均为 Keucher+CHS 合并版。");
                            } else {
                                ui.colored_label(MUTED, format!("待安装:{} 个 data.win。", a.to_patch));
                            }
                        }
                    }
                    }

                    ui.add_space(6.0);
                    ui.add_enabled(
                        !self.running,
                        egui::Checkbox::new(&mut self.backup, "安装前备份原文件(推荐)"),
                    );
                    ui.add_space(5.0);
                    ui.horizontal(|ui| {
                        let primary =
                            egui::Button::new(RichText::new(install_label).size(15.0).color(ON_PRIMARY))
                                .fill(PRIMARY)
                                .min_size(egui::vec2(116.0, 34.0));
                        act_apply = ui.add_enabled(can_install, primary).clicked();
                        act_restore = ui
                            .add_enabled(
                                !self.running && !self.assessing && self.has_backup,
                                egui::Button::new("卸载 / 还原"),
                            )
                            .clicked();
                        act_recheck = ui
                            .add_enabled(!self.running && !self.assessing, egui::Button::new("重新检测"))
                            .clicked();
                    });

                    if self.running {
                        ui.add_space(10.0);
                        ui.add(egui::ProgressBar::new(self.progress).show_percentage().animate(true));
                    }
                    if let Some(res) = &self.final_msg {
                        ui.add_space(8.0);
                        match res {
                            Ok(m) => {
                                ui.colored_label(OK, m);
                            }
                            Err(e) => {
                                ui.colored_label(DANGER, e);
                            }
                        }
                    }
                    if !self.log.is_empty() {
                        ui.add_space(10.0);
                        well(ui, |ui| {
                            for l in &self.log {
                                ui.label(RichText::new(l).monospace().size(12.5).color(MUTED));
                            }
                        });
                    }
                });
        });

        // 面板闭包外再执行会改动 self 的动作(避免同时借用多个字段)
        if act_browse {
            if let Some(dir) = rfd::FileDialog::new()
                .set_title("选择 DELTARUNE 安装目录")
                .pick_folder()
            {
                self.game_input = dir.display().to_string();
                self.set_game_from_input();
            }
        }
        if act_use || act_recheck {
            self.set_game_from_input();
        }
        if act_apply {
            self.start_apply();
        }
        if act_restore {
            self.start_restore();
        }

        if self.running || self.assessing {
            ui.ctx().request_repaint();
        }
    }
}
