import SwiftUI
import UIKit
import CoreText

/// 配色照网页 :root（明/暗两套），字体照网页栈：Lora（拉丁）→ Noto Serif CJK SC（中文，克正文 500 档）→ 系统宋体。
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color { Color(uiDyn(light, dark)) }
    static func uiDyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { tc in
            let h = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
    }
    static let bg = dyn(0xF9F9F7, 0x20201F)
    static let uiText = uiDyn(0x302D27, 0xE8E2D6)
    static let uiMuted = uiDyn(0x9B9183, 0x98907F)
    static let panel = dyn(0xF2EDE3, 0x2A2A27)
    static let text = dyn(0x302D27, 0xE8E2D6)
    static let muted = dyn(0x9B9183, 0x98907F)
    static let accent = Color(red: 0xC9/255, green: 0x64/255, blue: 0x42/255)
    static let userBubble = dyn(0xF1EFEB, 0x34332F)
    static let border = dyn(0xE4DDCF, 0x3A3833)
    static let composer = dyn(0xF2F2F2, 0x2E2E2B)
    static let boardBg = dyn(0xF6F2EF, 0x20201F)     // 留言板/抽屉页底（暖白）
    static let card = dyn(0xFAFAFA, 0x2A2A27)        // 留言卡/底栏白卡
    static let hairRing = dyn(0xFBFBFB, 0x3A3833)
    static let attachBg = dyn(0xF0EFEB, 0x34332F)
    static let menuFill = dyn(0xF2F2F2, 0x131313)
    static let jumpBg = dyn(0xF2F2F2, 0x2E2E2B)
    static let jumpArrow = dyn(0x131313, 0xE8E2D6)
    static let jumpRing = dyn(0xF9F9F9, 0x3A3833)
    static let sendIdle = dyn(0x131313, 0xFBFBFB)
    static let sendIdleFg = dyn(0xFFFFFF, 0x131313)
    static let knockBg = dyn(0xF3E5DD, 0x3A2C27)
    static let knockText = dyn(0x9C3D2E, 0xE0A48F)
    static let cacheTint = Color(red: 0xD9/255, green: 0x9A/255, blue: 0x66/255)
    /// 滚动条/光标/选中同色：rgba(217,119,87)
    static let scrollTint = Color(red: 217/255, green: 119/255, blue: 87/255)
    static let uiScrollTint = UIColor(red: 217/255, green: 119/255, blue: 87/255, alpha: 1)
    static let selection = Color(red: 0xEB/255, green: 0xC8/255, blue: 0xB6/255)

    // MARK: 字体：Lora 打头、中文回落到 Noto Serif CJK SC（CoreText 级联），再不行系统宋体。
    private static func cjkName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "NotoSerifCJKsc-Bold"
        case .semibold: return "NotoSerifCJKsc-SemiBold"
        case .medium: return "NotoSerifCJKsc-Medium"
        default: return "NotoSerifCJKsc-Regular"
        }
    }
    /// 字体名找不到（打包漏了/名字不对）就退到系统衬线，别整页变成 Helvetica。
    private static func descriptor(_ name: String, size: CGFloat, fallback: UIFontDescriptor) -> UIFontDescriptor {
        UIFont(name: name, size: size) != nil ? UIFontDescriptor(name: name, size: size) : fallback
    }
    private static func wght(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .bold, .heavy, .black: return 700
        case .semibold: return 600
        case .medium: return 500
        default: return 400
        }
    }
    /// 克正文那一套 UIFont：Lora 可变字体按 wght 轴实例化（网页 500）→ 中文级联 Noto Serif CJK SC 同档 → 系统宋体。
    static func uiSerif(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        let songti = UIFontDescriptor(name: "Songti SC", size: size)
        let cjk = descriptor(cjkName(weight), size: size, fallback: songti)
        var lora = descriptor("Lora-Regular", size: size, fallback: cjk)
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        lora = lora.addingAttributes([variation: [2003265652: wght(weight)],      // 'wght' 轴
                                      .cascadeList: [cjk, songti]])
        return UIFont(descriptor: lora, size: size)
    }
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Font(uiSerif(size, weight: weight)) }
    /// 中文回落字体本体（量自然行高用）
    static func uiCJK(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        UIFont(name: cjkName(weight), size: size) ?? UIFont(name: "Songti SC", size: size) ?? UIFont.systemFont(ofSize: size)
    }
    static func uiSongti(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size) ?? UIFont(name: "Songti SC", size: size) ?? UIFont.systemFont(ofSize: size)
    }
    // MARK: Cascadia Mono（寻 09-13）：界面和她的气泡里的字母、数字、英文标点走 Cascadia Mono。
    // 打包的是只含 ASCII（U+0020–007E）的子集（38 KB，可变字重 200–700）——其余字符它根本没有，
    // 一律落回后面的级联字体，所以汉字、中文标点、弯引号、emoji 都不会被它抢走。
    // 克的正文/思考链（uiSerif/cjk）和 Georgia 装饰字、Snell 花体不走这里（寻定：3、6 不换）。
    private static let casName = "CascadiaMono-Regular"
    private static func casDescriptor(_ size: CGFloat, wght: CGFloat, cascade: [UIFontDescriptor]) -> UIFontDescriptor? {
        guard UIFont(name: casName, size: size) != nil else { return nil }   // 字体没打进包就原样用后面的
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        return UIFontDescriptor(name: casName, size: size)
            .addingAttributes([variation: [2003265652: wght], .cascadeList: cascade])   // 'wght' 轴
    }
    private static func uiWeight(_ w: Font.Weight) -> UIFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
    private static func casWght(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .ultraLight, .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold, .heavy, .black: return 700
        default: return 400
        }
    }
    /// 界面通用字（原来的 .system）：Cascadia → 苹果系统字同字重
    static func uiSys(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        let sys = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        guard let d = casDescriptor(size, wght: casWght(weight), cascade: [sys.fontDescriptor]) else { return sys }
        return UIFont(descriptor: d, size: size)
    }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Font(uiSys(size, weight: weight)) }
    /// 圆体那一档（时间戳、纸条、搜索框）：Cascadia → 系统圆体
    static func uiRound(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        let rd = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        guard let d = casDescriptor(size, wght: casWght(weight), cascade: [rd]) else { return UIFont(descriptor: rd, size: size) }
        return UIFont(descriptor: d, size: size)
    }
    /// 等宽（工具行、代码块）：Cascadia → SF Mono
    static func uiMono(_ size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        let mono = UIFont.monospacedSystemFont(ofSize: size, weight: uiWeight(weight))
        guard let d = casDescriptor(size, wght: casWght(weight), cascade: [mono.fontDescriptor]) else { return mono }
        return UIFont(descriptor: d, size: size)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Font(uiMono(size, weight: weight)) }

    /// 寻那一套（09-13 起）：字母数字英文标点 Cascadia 400 → 汉字系统宋体；粗体 Cascadia 600 → 宋体粗
    static func uiUser(_ size: CGFloat, bold: Bool = false) -> UIFont {
        let song = uiSongti(size, bold: bold).fontDescriptor
        // 寻 09-13 晚：400 档挨着宋体显粗、320 又太细 → 360（可变字重 200–700 之间随调）
        guard let d = casDescriptor(size, wght: bold ? 600 : 360, cascade: [song]) else { return UIFont(descriptor: song, size: size) }
        return UIFont(descriptor: d, size: size)
    }
    /// 纯中文场合（门楣、题）：Noto 打头。
    static func cjk(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let songti = UIFontDescriptor(name: "Songti SC", size: size)
        let d = descriptor(cjkName(weight), size: size, fallback: songti)
            .addingAttributes([.cascadeList: [songti]])
        return Font(UIFont(descriptor: d, size: size))
    }
    /// 相册标题那一套（网页 Georgia, 'Lora', 'Songti SC', 'Noto Serif SC'，600）：英文 Georgia 粗 → 中文思源宋 SemiBold → 系统宋体
    static func georgiaCJK(_ size: CGFloat) -> Font {
        let songti = UIFontDescriptor(name: "Songti SC", size: size)
        let cjk = descriptor(cjkName(.semibold), size: size, fallback: songti)
        let g = descriptor("Georgia-Bold", size: size, fallback: cjk).addingAttributes([.cascadeList: [cjk, songti]])
        return Font(UIFont(descriptor: g, size: size))
    }
    static func round(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(uiRound(size, weight: weight))   // 09-13：圆体前头加 Cascadia（字母数字标点）
    }

    // MARK: 方舟像素 12 Mono（寻 09-15）：门楣天气、名字标签（留言板、档案馆命中行、日记卡）走这只。
    // 点阵字要在 12 的整数倍下才干净（12pt＝2 倍点阵），别拿 13 用；字母数字半角、汉字全角，本身就是等宽。
    // 包里是 GB2312＋ASCII 的子集（1.2 MB）；没有的字落回 Noto 宋。字体没打进包就整行退到圆体。
    static func uiPixel(_ size: CGFloat = 12) -> UIFont {
        let name = "Ark-Pixel-12px-Mono-zh_cn-Regular"
        guard UIFont(name: name, size: size) != nil else { return uiRound(size) }
        let d = UIFontDescriptor(name: name, size: size).addingAttributes([.cascadeList: [uiCJK(size).fontDescriptor]])
        return UIFont(descriptor: d, size: size)
    }
    static func pixel(_ size: CGFloat = 12) -> Font { Font(uiPixel(size)) }
}
