import SwiftUI
import UIKit

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
    static let panel = dyn(0xF2EDE3, 0x2A2A27)
    static let text = dyn(0x302D27, 0xE8E2D6)
    static let muted = dyn(0x9B9183, 0x98907F)
    static let accent = Color(red: 0xC9/255, green: 0x64/255, blue: 0x42/255)
    static let userBubble = dyn(0xF1EFEB, 0x34332F)
    static let border = dyn(0xE4DDCF, 0x3A3833)
    static let composer = dyn(0xF2F2F2, 0x2E2E2B)
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
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let songti = UIFontDescriptor(name: "Songti SC", size: size)
        let cjk = descriptor(cjkName(weight), size: size, fallback: songti)
        // Lora 可变字体只按 Regular 取（命名实例在 iOS 上不保险），拉丁字重交给系统合成
        let lora = descriptor("Lora-Regular", size: size, fallback: cjk)
            .addingAttributes([.cascadeList: [cjk, songti]])
        var f = UIFont(descriptor: lora, size: size)
        if weight == .bold || weight == .semibold || weight == .heavy || weight == .black,
           let bold = lora.withSymbolicTraits(.traitBold) { f = UIFont(descriptor: bold, size: size) }
        return Font(f)
    }
    /// 纯中文场合（门楣、题）：Noto 打头。
    static func cjk(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let songti = UIFontDescriptor(name: "Songti SC", size: size)
        let d = descriptor(cjkName(weight), size: size, fallback: songti)
            .addingAttributes([.cascadeList: [songti]])
        return Font(UIFont(descriptor: d, size: size))
    }
    static func round(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
