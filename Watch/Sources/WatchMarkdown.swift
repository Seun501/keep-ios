import SwiftUI
import UIKit

/// 表端字体链（09-21 寻定：和 App 一致，「基本就是克的消息和我的气泡」）。
/// 克＝Lora（wght 轴 400/500/600）→ 思源宋 GB2312 子集（Regular/Medium，各 2.1 MB）→ 系统衬线；
/// 她＝Cascadia（只含 ASCII，wght 360，同手机）→ 系统字（苹方）。
/// 斜体：Lora/思源宋都没有斜体面，同手机端一样斜 0.18（手机走 obliqueness，这里走字体矩阵——SwiftUI 的 Text 认 CoreText 的矩阵）。
enum WatchFonts {
    private static let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
    private static let slant = CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0)
    private static func desc(_ name: String, _ size: CGFloat) -> UIFontDescriptor? {
        UIFont(name: name, size: size) != nil ? UIFontDescriptor(name: name, size: size) : nil   // 没打进包就当没有，别整页变 Helvetica
    }
    private static func sysSerif(_ size: CGFloat, medium: Bool) -> UIFontDescriptor {
        let b = UIFont.systemFont(ofSize: size, weight: medium ? .medium : .regular).fontDescriptor
        return b.withDesign(.serif) ?? b
    }
    private static func make(_ d: UIFontDescriptor, _ size: CGFloat, italic: Bool) -> Font {
        Font(UIFont(descriptor: italic ? d.addingAttributes([.matrix: slant]) : d, size: size))
    }
    /// 克：wght 400 正文 / 500 标题 / 600 粗体（网页自托管思源宋只有 400/500/600，粗落 600；表上思源宋只带到 Medium，粗体汉字＝Medium）
    static func ke(_ size: CGFloat, wght: CGFloat = 400, italic: Bool = false) -> Font {
        let sys = sysSerif(size, medium: wght >= 500)
        let cjk = desc(wght >= 500 ? "NotoSerifCJKsc-Medium" : "NotoSerifCJKsc-Regular", size) ?? sys
        guard let lora = desc("Lora-Regular", size) else { return make(cjk, size, italic: italic) }
        return make(lora.addingAttributes([variation: [2003265652: wght], .cascadeList: [cjk, sys]]), size, italic: italic)
    }
    /// 她的气泡：手机端代码写的是 Cascadia→Songti SC，可 iPhone 上根本没这个字体名，一直落在系统字（苹方）——她看惯的就是这个
    /// （09-21 她说「我的气泡是苹方那一块的」）。表上照实际的来：Cascadia（ASCII，360；粗 600）→ 系统字（汉字＝苹方，粗＝半粗）。
    static func xun(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
        let sys = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
        guard let cas = desc("CascadiaMono-Regular", size) else { return make(sys, size, italic: italic) }
        return make(cas.addingAttributes([variation: [2003265652: bold ? 600 : 360], .cascadeList: [sys]]), size, italic: italic)
    }
    static func mono(_ size: CGFloat) -> Font {
        let m = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let cas = desc("CascadiaMono-Regular", size) else { return Font(m) }
        return Font(UIFont(descriptor: cas.addingAttributes([variation: [2003265652: 400], .cascadeList: [m.fontDescriptor]]), size: size))
    }
    /// 启动时记一行：表上有没有这几个字体（盲调试）
    static var report: String {
        ["STSongti-SC-Regular", "Songti SC", "NotoSerifCJKsc-Regular", "Lora-Regular", "CascadiaMono-Regular"]
            .map { "\($0.split(separator: "-").first ?? "?")=\(UIFont(name: $0, size: 12) != nil ? 1 : 0)" }.joined(separator: " ")
    }
}

/// 表端 Markdown（09-21 寻要的）：块级照手机端 MD.parse 的规则（围栏代码、# 标题、> 引用、-/* 列表含缩进子项、1. 列表、---），
/// 行内照手机端 MD.ns 那四条正则（`代码`、**粗**、~~删除线~~、*斜*）逐段配字——SwiftUI 对自定义字体不会自己换字重/斜（寻验：斜体没出）。
/// 表格太窄，按普通行画。
enum WMD {
    enum Block {
        case para(String)
        case heading(Int, String)
        case quote(String)
        case code(String)
        case ul([(Int, String)])          // (缩进级, 正文)
        case ol([(Int, Int, String)])     // (缩进级, 序号, 正文)
        case hr
    }
    struct Run { var text: String; var kind: Character }   // n 正文 / b 粗 / e 斜 / c 代码 / d 删除线
    static func runs(_ s: String) -> [Run] {
        let pats: [(String, Character)] = [("`([^`]+)`", "c"), ("\\*\\*([^*]+)\\*\\*", "b"), ("~~(?=\\S)([^~\\n]*?\\S)~~", "d"), ("(?<![*])\\*([^*\\n]+)\\*", "e")]
        func split(_ t: String, _ pi: Int) -> [Run] {
            if pi >= pats.count { return t.isEmpty ? [] : [Run(text: t, kind: "n")] }
            guard let re = try? NSRegularExpression(pattern: pats[pi].0) else { return split(t, pi + 1) }
            var out: [Run] = []; var last = 0
            let ns = t as NSString
            for mt in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                if mt.range.location > last { out += split(ns.substring(with: NSRange(location: last, length: mt.range.location - last)), pi + 1) }
                out.append(Run(text: ns.substring(with: mt.range(at: 1)), kind: pats[pi].1))
                last = mt.range.location + mt.range.length
            }
            if last < ns.length { out += split(ns.substring(from: last), pi + 1) }
            return out
        }
        return split(s, 0)
    }
    static func parse(_ text: String) -> [Block] {
        var fences: [String] = []
        var t = text
        while let r = t.range(of: "```") {
            guard let r2 = t.range(of: "```", range: r.upperBound..<t.endIndex) else { break }
            var code = String(t[r.upperBound..<r2.lowerBound])
            if let nl = code.firstIndex(of: "\n"), code[..<nl].allSatisfy({ $0.isLetter || $0.isNumber }) { code = String(code[code.index(after: nl)...]) }   // 去掉语言标记行
            if code.hasSuffix("\n") { code.removeLast() }
            fences.append(code)
            t.replaceSubrange(r.lowerBound..<r2.upperBound, with: "\u{0}\(fences.count - 1)\u{0}")
        }
        let lines = t.components(separatedBy: "\n")
        func indent(_ l: String) -> Int { var n = 0; for c in l { if c == " " { n += 1 } else if c == "\t" { n += 2 } else { break } }; return min(3, n / 2) }
        func after(_ s: Substring, _ end: Substring.Index) -> String? {
            guard end < s.endIndex, s[end] == " " || s[end] == "\t" else { return nil }
            return String(s[end...]).trimmingCharacters(in: .whitespaces)
        }
        func ul(_ l: String) -> (Int, String)? {
            let s = l.drop { $0 == " " || $0 == "\t" }
            guard let f = s.first, f == "-" || f == "*" || f == "•", let body = after(s, s.index(after: s.startIndex)) else { return nil }
            return (indent(l), body)
        }
        func ol(_ l: String) -> (Int, Int, String)? {
            let s = l.drop { $0 == " " || $0 == "\t" }
            guard let dot = s.firstIndex(where: { $0 == "." || $0 == "、" }), let n = Int(s[..<dot]), let body = after(s, s.index(after: dot)) else { return nil }
            return (indent(l), n, body)
        }
        func heading(_ l: String) -> (Int, String)? {
            var n = 0; var i = l.startIndex
            while i < l.endIndex, l[i] == "#" { n += 1; i = l.index(after: i) }
            guard n >= 1, n <= 6, i < l.endIndex, l[i] == " " || l[i] == "\t" else { return nil }
            return (n, String(l[i...]).trimmingCharacters(in: .whitespaces))
        }
        func quote(_ l: String) -> String? {
            guard l.hasPrefix(">") else { return nil }
            var s = String(l.dropFirst()); if s.hasPrefix(" ") { s.removeFirst() }; return s
        }
        func code(_ l: String) -> Int? {
            guard l.hasPrefix("\u{0}"), l.hasSuffix("\u{0}"), l.count >= 3 else { return nil }
            return Int(l.dropFirst().dropLast())
        }
        func isHr(_ l: String) -> Bool { let s = l.trimmingCharacters(in: .whitespaces); return s.count >= 3 && (s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" }) }
        func special(_ l: String) -> Bool { code(l) != nil || heading(l) != nil || quote(l) != nil || ul(l) != nil || ol(l) != nil || isHr(l) }

        var out: [Block] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if let ci = code(l), ci < fences.count { out.append(.code(fences[ci])); i += 1; continue }
            if isHr(l) { out.append(.hr); i += 1; continue }
            if let (lv, s) = heading(l) { out.append(.heading(lv, s)); i += 1; continue }
            if quote(l) != nil {
                var q: [String] = []
                while i < lines.count, let s = quote(lines[i]) { q.append(s); i += 1 }
                out.append(.quote(q.joined(separator: "\n"))); continue
            }
            if ul(l) != nil || ol(l) != nil {
                // 有序/无序混排（克常在「1. 」底下缩两格写「- 」）：按首行的种类归块，子项跟着走
                if ol(l) != nil {
                    var it: [(Int, Int, String)] = []
                    while i < lines.count, let x = ol(lines[i]) ?? ul(lines[i]).map({ ($0.0, 0, $0.1) }) { it.append(x); i += 1 }
                    out.append(.ol(it))
                } else {
                    var it: [(Int, String)] = []
                    while i < lines.count, let x = ul(lines[i]) ?? ol(lines[i]).map({ ($0.0, "\($0.1). " + $0.2) }) { it.append(x); i += 1 }
                    out.append(.ul(it))
                }
                continue
            }
            var p: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !special(lines[i]) { p.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1 }
            out.append(.para(p.joined(separator: "\n")))
        }
        return out
    }
}

/// 表上的一条：mine＝她的气泡（苹方那套、标题照网页 .user .bubble h1–h6 的倍率），否则克的（Lora→思源宋）。
/// 间距照手机端比例缩到 14 号：段间 0.7em（手机 16/18）、标题下 0.5em、列表项间 3、行距 1.45。
struct WatchMarkdown: View {
    let text: String
    var mine = false
    var size: CGFloat = 14
    var body: some View {
        let blocks = WMD.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b).padding(.bottom, i == blocks.count - 1 ? 0 : gap(b))
            }
        }
    }
    private func gap(_ b: WMD.Block) -> CGFloat {
        switch b {
        case .heading: return size * 0.35
        case .hr: return size * 0.4
        default: return size * 0.7
        }
    }
    private func font(_ wght: CGFloat = 400, italic: Bool = false) -> Font {
        mine ? WatchFonts.xun(size, bold: wght >= 600, italic: italic) : WatchFonts.ke(size, wght: wght, italic: italic)
    }
    private func hfont(_ lv: Int) -> Font {
        if mine {
            let hs = size * [1.3, 1.18, 1.06, 1.0, 0.92, 0.85][lv - 1]
            return WatchFonts.xun(hs, bold: true)
        }
        return WatchFonts.ke(lv <= 2 ? size + 3 : size + 0.5, wght: 500)
    }
    @ViewBuilder private func block(_ b: WMD.Block) -> some View {
        switch b {
        case .para(let s): inline(s)
        case .heading(let lv, let s): inline(s, base: hfont(lv), hBold: true).foregroundStyle(mine && lv == 6 ? AnyShapeStyle(.secondary) : AnyShapeStyle(WatchTheme.text))
        case .quote(let s):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(WatchTheme.accent.opacity(0.7)).frame(width: 2)
                inline(s).foregroundStyle(.secondary)
            }
        case .code(let s):
            Text(s).font(WatchFonts.mono(size - 3)).foregroundStyle(WatchTheme.text)
                .padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: mine ? nil : .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .ul(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").font(font())
                        inline(items[i].1)
                    }.padding(.leading, CGFloat(items[i].0) * 10)
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 5) {
                        Text(items[i].1 == 0 ? "•" : "\(items[i].1).").font(font())
                        inline(items[i].2)
                    }.padding(.leading, CGFloat(items[i].0) * 10)
                }
            }
        case .hr: Rectangle().fill(WatchTheme.line).frame(height: 1).padding(.vertical, 2)
        }
    }
    /// 行内：逐段配字拼成一个 Text（换行照排）
    private func inline(_ s: String, base: Font? = nil, hBold: Bool = false) -> some View {
        var t = Text("")
        for r in WMD.runs(s) {
            var piece: Text
            switch r.kind {
            case "b": piece = Text(r.text).font(hBold ? (base ?? font(600)) : font(600))
            case "e": piece = Text(r.text).font(hBold ? (base ?? font(400, italic: true)) : font(400, italic: true))
            case "c": piece = Text(r.text).font(WatchFonts.mono(size - 2))
            case "d": piece = Text(r.text).font(base ?? font()).strikethrough(true, color: WatchTheme.text.opacity(0.65)).foregroundColor(WatchTheme.text.opacity(0.65))
            default: piece = Text(r.text).font(base ?? font())
            }
            t = t + piece
        }
        // 她的气泡要贴着字长（09-21 夜寻：短消息也被撑满一行）——只有克的正文才撑满宽
        return t.foregroundStyle(WatchTheme.text).lineSpacing(size * 0.2).frame(maxWidth: mine ? nil : .infinity, alignment: .leading)
    }
}
