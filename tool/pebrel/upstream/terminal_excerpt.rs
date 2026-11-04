pub enum ThemeName {
    Nebula,
    SilverLight,
    SteelDark,
    LimestoneLight,
    CoalDark,
    LinenLight,
    MossDark,
    /// 深色：Nord 配色（Arctic Ice Studio 公开色板）。出厂默认。
    ///
    /// 跟随系统时与 Nord Light 配对；显式主题选择保持独立。
    #[default]
    Nord,
    /// 浅色：基于 Nord 色板的浅色适配。
    NordLight,
    /// Warm Sand；保留 Rust 变体名与旧 Paper 配置的兼容读取。
    Paper,
    BreezeLight,
    BreezeDark,
    MintLight,
    MintDark,
    CatppuccinMocha,
    CatppuccinLatte,
    CatppuccinFrappe,
    CatppuccinMacchiato,
    /// Slate Light；兼容旧 GlassLight 标识。
    GlassLight,
    GlassDark,
}

impl ThemeName {
    pub fn from_prompt_name(name: &str) -> Option<Self> {
        Some(match name {
            "Nebula" => Self::Nebula,
            "SilverLight" => Self::SilverLight,
            "SteelDark" => Self::SteelDark,
            "LimestoneLight" => Self::LimestoneLight,
            "CoalDark" => Self::CoalDark,
            "LinenLight" => Self::LinenLight,
            "MossDark" => Self::MossDark,
            "Nord" => Self::Nord,
            "Paper" | "WarmSand" => Self::Paper,
            "NordLight" => Self::NordLight,
            "BreezeLight" => Self::BreezeLight,
            "BreezeDark" => Self::BreezeDark,
            "MintLight" => Self::MintLight,
            "MintDark" => Self::MintDark,
            "CatppuccinMocha" => Self::CatppuccinMocha,
            "CatppuccinLatte" => Self::CatppuccinLatte,
            "CatppuccinFrappe" => Self::CatppuccinFrappe,
            "CatppuccinMacchiato" => Self::CatppuccinMacchiato,
            "GlassLight" | "SlateLight" => Self::GlassLight,
            "GlassDark" => Self::GlassDark,

            _ => return None,
        })
    }

    pub const fn prompt_name(self) -> &'static str {
        match self {
            Self::Nebula => "Nebula",
            Self::SilverLight => "SilverLight",
            Self::SteelDark => "SteelDark",
            Self::LimestoneLight => "LimestoneLight",
            Self::CoalDark => "CoalDark",
            Self::LinenLight => "LinenLight",
            Self::MossDark => "MossDark",
            Self::Nord => "Nord",
            Self::Paper => "WarmSand",
            Self::NordLight => "NordLight",
            Self::BreezeLight => "BreezeLight",
            Self::BreezeDark => "BreezeDark",
            Self::MintLight => "MintLight",
            Self::MintDark => "MintDark",
            Self::CatppuccinMocha => "CatppuccinMocha",
            Self::CatppuccinLatte => "CatppuccinLatte",
            Self::CatppuccinFrappe => "CatppuccinFrappe",
            Self::CatppuccinMacchiato => "CatppuccinMacchiato",
            Self::GlassLight => "SlateLight",
            Self::GlassDark => "GlassDark",
        }
    }

    /// 主题对终端色表的全部影响（旧壳 `apply_term_colors` 的数据形态）。
    pub fn term_theme(self) -> TermTheme {
        // 背景与 is_light 来自各主题 palette()；powerline 为提示符段色
        // （icon bg/fg、path bg/fg、branch bg/fg、time bg/fg）。
        match self {
            Self::NordLight
            | Self::Paper
            | Self::BreezeLight
            | Self::BreezeDark
            | Self::MintLight
            | Self::MintDark
            | Self::CatppuccinMocha
            | Self::CatppuccinLatte
            | Self::CatppuccinFrappe
            | Self::CatppuccinMacchiato
            | Self::GlassLight
            | Self::GlassDark => themes::fresh_terminal(self),
            Self::Nebula => TermTheme {
                background: [15, 17, 26],
                is_light: false,
                exact: None,
                powerline: [
                    [57, 75, 112],
                    [192, 202, 245],
                    [41, 52, 82],
                    [169, 177, 214],
                    [47, 79, 79],
                    [139, 213, 202],
                    [29, 33, 46],
                    [100, 116, 139],
                ],
            },
            Self::SilverLight => TermTheme {
                background: [255, 255, 255],
                is_light: true,
                exact: None,
                powerline: [
                    [229, 231, 235],
                    [55, 65, 81],
                    [243, 244, 246],
                    [55, 65, 81],
                    [224, 242, 254],
                    [3, 105, 161],
                    [249, 250, 251],
                    [107, 114, 128],
                ],
            },
            Self::SteelDark => TermTheme {
                background: [26, 28, 36],
                is_light: false,
                exact: None,
                powerline: [
                    [71, 85, 105],
                    [241, 245, 249],
                    [51, 65, 85],
                    [203, 213, 225],
                    [59, 82, 73],
                    [163, 184, 153],
                    [40, 44, 56],
                    [148, 163, 184],
                ],
            },
            Self::LimestoneLight => TermTheme {
                background: [255, 255, 255],
                is_light: true,
                exact: None,
                powerline: [
                    [214, 211, 209],
                    [250, 250, 249],
                    [231, 229, 228],
                    [68, 64, 60],
                    [200, 198, 167],
                    [41, 37, 36],
                    [235, 233, 230],
                    [163, 160, 151],
                ],
            },
            Self::CoalDark => TermTheme {
                background: [23, 23, 23],
                is_light: false,
                exact: None,
                powerline: [
                    [82, 82, 82],
                    [245, 245, 245],
                    [64, 64, 64],
                    [212, 212, 212],
                    [74, 79, 65],
                    [181, 181, 166],
                    [48, 48, 48],
                    [115, 115, 115],
                ],
            },
            Self::LinenLight => TermTheme {
                background: [255, 255, 255],
                is_light: true,
                exact: None,
                powerline: [
                    [212, 212, 208],
                    [255, 255, 255],
                    [229, 229, 223],
                    [63, 63, 63],
                    [181, 196, 177],
                    [45, 45, 45],
                    [236, 236, 230],
                    [176, 179, 176],
                ],
            },
            Self::MossDark => TermTheme {
                background: [30, 33, 30],
                is_light: false,
                exact: None,
                powerline: [
                    [75, 85, 72],
                    [240, 253, 244],
                    [59, 66, 56],
                    [220, 252, 231],
                    [60, 79, 60],
                    [187, 247, 208],
                    [42, 47, 42],
                    [107, 114, 107],
                ],
            },
            Self::Nord => TermTheme {
                background: [0x2e, 0x34, 0x40],
                is_light: false,
                exact: Some(ExactTermColors {
                    foreground: [0xf1, 0xf6, 0xff],
                    ansi: [
                        [0x3b, 0x42, 0x52],
                        [0xbf, 0x61, 0x6a],
                        [0xa3, 0xbe, 0x8c],
                        [0xeb, 0xcb, 0x8b],
                        [0x81, 0xa1, 0xc1],
                        [0xb4, 0x8e, 0xad],
                        [0x88, 0xc0, 0xd0],
                        [0xe5, 0xe9, 0xf0],
                        [0x4c, 0x56, 0x6a],
                        [0xbf, 0x61, 0x6a],
                        [0xa3, 0xbe, 0x8c],
                        [0xeb, 0xcb, 0x8b],
                        [0x81, 0xa1, 0xc1],
                        [0xb4, 0x8e, 0xad],
                        [0x8f, 0xbc, 0xbb],
                        [0xec, 0xef, 0xf4],
                    ],
                    cursor: Some([0xe5, 0xe9, 0xf0]),
                    cursor_text: Some([0x2e, 0x34, 0x40]),
                    cursor_stroke: Some([0x88, 0xc0, 0xd0]),
                    selection_foreground: Some([0x2e, 0x34, 0x40]),
                    selection_background: Some([0xe5, 0xe9, 0xf0]),
                }),
                // Nord 色板没有 Nebula 的 Powerline 槽位；以下只用它的
                // surface / ANSI / token 色为 Nebula 提示符保持同主题可读性。
                powerline: [
                    [0x3b, 0x42, 0x52],
                    [0xec, 0xef, 0xf4],
                    [0x4c, 0x56, 0x6a],
                    [0xe5, 0xe9, 0xf0],
                    [0x43, 0x4c, 0x5e],
                    [0x88, 0xc0, 0xd0],
                    [0x2e, 0x34, 0x40],
                    [0x7b, 0x82, 0x94],
                ],
            },
        }
    }

    /// Built-in themes share a flat terminal surface. Window/widget radii are separate.
    /// Explicit user geometry remains configurable; choosing a preset restores its geometry.
    pub fn card_geometry(self) -> ThemeCardGeometry {
        ThemeCardGeometry { radius: 0.0, gutter: 0.0, shadow: false, divider: 1.0 }
    }
}

/// 主题明确携带的终端色表。`None` 字段表示主题没有声明该值，调用方应保留
/// 用户配置或宿主默认值；这对没有 cursor/selection 数据的 Paper 很重要。
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct ExactTermColors {
    pub foreground: Rgb8,
    pub ansi: [Rgb8; 16],
    pub cursor: Option<Rgb8>,
    pub cursor_text: Option<Rgb8>,
    pub cursor_stroke: Option<Rgb8>,
    pub selection_foreground: Option<Rgb8>,
    pub selection_background: Option<Rgb8>,
}

/// 一个主题对终端色表的影响。浅色主题额外用 [`LIGHT_FOREGROUND`] 与
/// [`LIGHT_ANSI`] 替换前景与 ANSI-16（配置的暗底配色在浅底上不可读）。
/// dim 表与 bright_foreground 有意不动——与旧壳逐字段一致。
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct TermTheme {
    pub background: Rgb8,
    pub is_light: bool,
    /// 只有自带完整终端 palette 的主题使用；现有七个主题保持 `None`，继续
    /// 走原来的背景/浅色替换合同。
    pub exact: Option<ExactTermColors>,
    /// 旧提示符段色参考；不再发布到终端扩展色表。
    pub powerline: [Rgb8; 8],
}

/// 浅色主题的替换前景（#24292f）。
pub const LIGHT_FOREGROUND: Rgb8 = [36, 41, 47];

/// 浅色主题的 ANSI-16 替换表（GitHub Primer Light 派生；BrightWhite 刻意
/// 用灰——纯白会消失在白底终端上）。
pub const LIGHT_ANSI: [Rgb8; 16] = [
    [36, 41, 47],    // black #24292f
    [207, 34, 46],   // red #cf222e
    [26, 127, 55],   // green #1a7f37
    [154, 103, 0],   // yellow #9a6700
    [9, 105, 218],   // blue #0969da
    [130, 80, 223],  // magenta #8250df
    [27, 124, 131],  // cyan #1b7c83
    [110, 119, 129], // white #6e7781
    [87, 96, 106],   // bright black #57606a
    [164, 14, 38],   // bright red #a40e26
    [45, 164, 78],   // bright green #2da44e
    [191, 135, 0],   // bright yellow #bf8700
    [33, 139, 255],  // bright blue #218bff
    [164, 117, 249], // bright magenta #a475f9
    [49, 146, 170],  // bright cyan #3192aa
    [140, 149, 159], // bright white #8c959f
];
