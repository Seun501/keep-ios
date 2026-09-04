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
    /// 寻那一套（网页 body：'Lora', Georgia, 'Songti SC'）：Lora 400 → 系统宋体；粗体 Lora 600 → 宋体粗
    static func uiUser(_ size: CGFloat, bold: Bool = false) -> UIFont {
        let song = uiSongti(size, bold: bold).fontDescriptor
        var lora = descriptor("Lora-Regular", size: size, fallback: song)
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        lora = lora.addingAttributes([variation: [2003265652: bold ? 600 : 400], .cascadeList: [song]])
        return UIFont(descriptor: lora, size: size)
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
        .system(size: size, weight: weight, design: .rounded)
    }
}
