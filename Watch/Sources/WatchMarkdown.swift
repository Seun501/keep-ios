import SwiftUI
import UIKit

/// 表端字体链（09-21 寻定：和 App 一致，「基本就是克的消息和我的气泡」）。
/// 克＝Lora（wght 轴 400/500）→ 思源宋 GB2312 子集（Regular/Medium，各 2.1 MB）→ 系统衬线；
/// 她＝Cascadia（只含 ASCII，wght 360，同手机）→ 思源宋 Regular。表上没有手机那套「Songti SC」系统宋，末尾退系统衬线。
enum WatchFonts {
    private static let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
    private static func desc(_ name: String, _ size: CGFloat) -> UIFontDescriptor? {
        UIFont(name: name, size: size) != nil ? UIFontDescriptor(name: name, size: size) : nil   // 没打进包就当没有，别整页变 Helvetica
    }
    private static func sysSerif(_ size: CGFloat, medium: Bool) -> UIFontDescriptor {
        let b = UIFont.systemFont(ofSize: size, weight: medium ? .medium : .regular).fontDescriptor
        return b.withDesign(.serif) ?? b
    }
    static func ke(_ size: CGFloat, medium: Bool = false) -> Font {
        let sys = sysSerif(size, medium: medium)
        let cjk = desc(medium ? "NotoSerifCJKsc-Medium" : "NotoSerifCJKsc-Regular", size) ?? sys
        guard let lora = desc("Lora-Regular", size) else { return Font(UIFont(descriptor: cjk, size: size)) }
        let d = lora.addingAttributes([variation: [2003265652: medium ? 500 : 400], .cascadeList: [cjk, sys]])
        return Font(UIFont(descriptor: d, size: size))
    }
    static func xun(_ size: CGFloat) -> Font {
        let sys = sysSerif(size, medium: false)
        let cjk = desc("NotoSerifCJKsc-Regular", size) ?? sys
        guard let cas = desc("CascadiaMono-Regular", size) else { return Font(UIFont(descriptor: cjk, size: size)) }
        let d = cas.addingAttributes([variation: [2003265652: 360], .cascadeList: [cjk, sys]])
        return Font(UIFont(descriptor: d, size: size))
    }
    static func mono(_ size: CGFloat) -> Font {
        let m = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let cas = desc("CascadiaMono-Regular", size) else { return Font(m) }
        return Font(UIFont(descriptor: cas.addingAttributes([variation: [2003265652: 400], .cascadeList: [m.fontDescriptor]]), size: size))
    }
}

/// 表端 Markdown（09-21 寻要的）：块级照手机端 MD.parse 的规则（围栏代码、# 标题、> 引用、-/* 列表含缩进子项、1. 列表、---），
/// 行内粗斜体/代码交给系统的 AttributedString(markdown:)。表格太窄，按普通行画。
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

struct WatchMarkdown: View {
    let text: String
    var size: CGFloat = 14
    var body: some View {
        let blocks = WMD.parse(text)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
    }
    @ViewBuilder private func block(_ b: WMD.Block) -> some View {
        switch b {
        case .para(let s): inline(s, WatchFonts.ke(size))
        case .heading(let lv, let s): inline(s, WatchFonts.ke(lv <= 1 ? size + 3 : lv == 2 ? size + 2 : size + 1, medium: true)).padding(.top, 2)
        case .quote(let s):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(WatchTheme.accent.opacity(0.7)).frame(width: 2)
                inline(s, WatchFonts.ke(size)).foregroundStyle(.secondary)
            }
        case .code(let s):
            Text(s).font(WatchFonts.mono(size - 3)).foregroundStyle(WatchTheme.text)
                .padding(.horizontal, 6).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .ul(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 5) {
                        Text("•").font(WatchFonts.ke(size))
                        inline(items[i].1, WatchFonts.ke(size))
                    }.padding(.leading, CGFloat(items[i].0) * 10)
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 5) {
                        Text(items[i].1 == 0 ? "•" : "\(items[i].1).").font(WatchFonts.ke(size))
                        inline(items[i].2, WatchFonts.ke(size))
                    }.padding(.leading, CGFloat(items[i].0) * 10)
                }
            }
        case .hr: Rectangle().fill(WatchTheme.line).frame(height: 1).padding(.vertical, 2)
        }
    }
    private func inline(_ s: String, _ f: Font) -> some View {
        let a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(a).font(f).foregroundStyle(WatchTheme.text).frame(maxWidth: .infinity, alignment: .leading)
    }
}
