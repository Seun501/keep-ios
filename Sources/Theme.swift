import SwiftUI

/// 配色照网页 :root（明/暗两套），字体照网页：正文衬线、小字圆体。
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { tc in
            let h = tc.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
    static let bg = dyn(0xF9F9F7, 0x20201F)
    static let panel = dyn(0xF2EDE3, 0x2A2A27)
    static let text = dyn(0x302D27, 0xE8E2D6)
    static let muted = dyn(0x9B9183, 0x98907F)
    static let accent = Color(red: 0xC9/255, green: 0x64/255, blue: 0x42/255)
    static let userBubble = dyn(0xF1EFEB, 0x34332F)
    static let border = dyn(0xE4DDCF, 0x3A3833)
    static let composer = dyn(0xF2F2F2, 0x2E2E2B)
    static let knockBg = dyn(0xF3E5DD, 0x3A2C27)
    static let knockText = dyn(0x9C3D2E, 0xE0A48F)
    static let cacheTint = Color(red: 0xD9/255, green: 0x9A/255, blue: 0x66/255)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }
    static func round(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
