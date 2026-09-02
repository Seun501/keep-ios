import SwiftUI

/// 极简 Markdown，块级规则照网页 renderMarkdown：围栏代码、#标题、>引用、-/* 列表、1. 列表（带原序号）、表格、段落。
/// 行内交给系统（**粗体** *斜体* `代码` ~~删除线~~），只做行内、保留空白。
enum MD {
    enum Block: Identifiable {
        case para([String])                 // 行，段内换行照排
        case heading(Int, String)
        case code(String)
        case quote([String])
        case ul([String])
        case ol([(Int, String)])
        case table(head: [String], rows: [[String]])
        var id: String { UUID().uuidString }
    }

    static func inline(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// 行内 markdown → 逐段落字：SwiftUI 对自定义字体不会自己把 **粗体** 换字重（构建 13 寻验「没渲染」），
    /// 这里按 intent 显式给每段配字：正文 base，粗体升档，代码等宽，删除线画线。
    static func styled(_ s: String, base: UIFont, bold: UIFont, mono: UIFont, color: Color) -> AttributedString {
        var a = inline(s)
        a.font = base
        a.foregroundColor = color
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let r = run.range
            if intent.contains(.stronglyEmphasized) { a[r].font = bold }
            if intent.contains(.code) { a[r].font = mono }
            if intent.contains(.strikethrough) { a[r].strikethroughStyle = .single; a[r].foregroundColor = color.opacity(0.65) }
        }
        return a
    }
    /// 同上，但产出 NSAttributedString 给 UITextView（粗体/代码/删除线原生生效；精确选字）。lineHeight＝网页 line-height 倍数。
    static func ns(_ s: String, base: UIFont, bold: UIFont, mono: UIFont, color: UIColor, lineHeight: CGFloat) -> NSAttributedString {
        let a = inline(s)
        let m = NSMutableAttributedString(string: String(a.characters))
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = base.pointSize * lineHeight
        para.maximumLineHeight = base.pointSize * lineHeight
        let all = NSRange(location: 0, length: m.length)
        m.addAttributes([.font: base, .foregroundColor: color, .paragraphStyle: para,
                         .baselineOffset: max(0, (base.pointSize * lineHeight - base.lineHeight) / 4)], range: all)
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let r = NSRange(run.range, in: a)
            if intent.contains(.stronglyEmphasized) { m.addAttribute(.font, value: bold, range: r) }
            if intent.contains(.code) { m.addAttribute(.font, value: mono, range: r) }
            if intent.contains(.strikethrough) {
                m.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                 .foregroundColor: color.withAlphaComponent(0.65)], range: r)
            }
        }
        return m
    }
    static func keNS(_ s: String, size: CGFloat = 18, weight: Font.Weight = .medium, color: UIColor = Theme.uiText, lineHeight: CGFloat = 1.6) -> NSAttributedString {
        ns(s, base: Theme.uiSerif(size, weight: weight), bold: Theme.uiSerif(size, weight: .bold),
           mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: color, lineHeight: lineHeight)
    }
    static func xunNS(_ s: String, size: CGFloat = 18) -> NSAttributedString {
        ns(s, base: UIFont.systemFont(ofSize: size), bold: UIFont.systemFont(ofSize: size, weight: .semibold),
           mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: Theme.uiText, lineHeight: 1.5)
    }
    static func ke(_ s: String, size: CGFloat = 18, weight: Font.Weight = .medium) -> AttributedString {
        styled(s, base: Theme.uiSerif(size, weight: weight), bold: Theme.uiSerif(size, weight: .bold),
               mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: Theme.text)
    }
    static func xun(_ s: String, size: CGFloat = 17) -> AttributedString {
        styled(s, base: UIFont.systemFont(ofSize: size), bold: UIFont.systemFont(ofSize: size, weight: .semibold),
               mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: Theme.text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [String] = []
        var t = text
        // 围栏代码先抠出去
        while let r = t.range(of: "```") {
            guard let r2 = t.range(of: "```", range: r.upperBound..<t.endIndex) else { break }
            var code = String(t[r.upperBound..<r2.lowerBound])
            if code.hasPrefix("\n") { code.removeFirst() }
            if code.hasSuffix("\n") { code.removeLast() }
            blocks.append(code)
            t.replaceSubrange(r.lowerBound..<r2.upperBound, with: "\u{0}\(blocks.count - 1)\u{0}")
        }
        let lines = t.components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        func isTable(_ idx: Int) -> Bool {
            guard idx + 1 < lines.count, lines[idx].contains("|") else { return false }
            let sep = lines[idx + 1]
            return sep.contains("-") && sep.contains("|") && sep.allSatisfy { " |:-".contains($0) }
        }
        func codeIndex(_ line: String) -> Int? {
            guard line.hasPrefix("\u{0}"), line.hasSuffix("\u{0}"), line.count >= 3 else { return nil }
            return Int(line.dropFirst().dropLast())
        }
        func heading(_ line: String) -> (Int, String)? {
            var n = 0; var idx = line.startIndex
            while idx < line.endIndex, line[idx] == "#" { n += 1; idx = line.index(after: idx) }
            guard n >= 1, n <= 6, idx < line.endIndex, line[idx] == " " else { return nil }
            return (n, String(line[idx...]).trimmingCharacters(in: .whitespaces))
        }
        func olItem(_ line: String) -> (Int, String)? {
            guard let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]),
                  line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " else { return nil }
            return (n, String(line[line.index(dot, offsetBy: 2)...]))
        }
        func ulItem(_ line: String) -> String? {
            (line.hasPrefix("- ") || line.hasPrefix("* ")) ? String(line.dropFirst(2)) : nil
        }
        func quoteLine(_ line: String) -> String? {
            guard line.hasPrefix(">") else { return nil }
            var s = String(line.dropFirst()); if s.hasPrefix(" ") { s.removeFirst() }; return s
        }
        func isSpecial(_ idx: Int) -> Bool {
            let l = lines[idx]
            return codeIndex(l) != nil || heading(l) != nil || quoteLine(l) != nil || ulItem(l) != nil || olItem(l) != nil || isTable(idx)
        }
        func cells(_ row: String) -> [String] {
            var r = row.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i]
            if let ci = codeIndex(line), ci < blocks.count { out.append(.code(blocks[ci])); i += 1; continue }
            if let (lv, s) = heading(line) { out.append(.heading(lv, s)); i += 1; continue }
            if quoteLine(line) != nil {
                var q: [String] = []
                while i < lines.count, let s = quoteLine(lines[i]) { q.append(s); i += 1 }
                out.append(.quote(q)); continue
            }
            if ulItem(line) != nil {
                var it: [String] = []
                while i < lines.count, let s = ulItem(lines[i]) { it.append(s); i += 1 }
                out.append(.ul(it)); continue
            }
            if olItem(line) != nil {
                var it: [(Int, String)] = []
                while i < lines.count, let s = olItem(lines[i]) { it.append(s); i += 1 }
                out.append(.ol(it)); continue
            }
            if isTable(i) {
                let head = cells(lines[i]); i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                out.append(.table(head: head, rows: rows)); continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            var para: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !isSpecial(i) {
                para.append(lines[i]); i += 1
            }
            out.append(.para(para))
        }
        return out
    }
}

/// 克的正文。
struct MarkdownView: View {
    let text: String
    var body: some View {
        let blocks = MD.parse(text)
        VStack(alignment: .leading, spacing: 16) {   // .ai .bubble p { margin: 16px 0 }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
    }

    @ViewBuilder private func block(_ b: MD.Block) -> some View {
        switch b {
        case .para(let lines):
            RichText(attr: MD.keNS(lines.joined(separator: "\n")))
        case .heading(let lv, let s):
            RichText(attr: MD.keNS(s, size: lv <= 2 ? 21 : 18.5, weight: .semibold, lineHeight: 1.35))
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(.system(size: 13.5, design: .monospaced)).foregroundColor(Theme.text)
                    .padding(10)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let q):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.border).frame(width: 3)
                RichText(attr: MD.keNS(q.joined(separator: "\n"), color: Theme.uiMuted))
            }
        case .ul(let items):   // 网页 ul/ol：padding-left 2em、li 间 3
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted).frame(width: 22, alignment: .trailing)
                        RichText(attr: MD.keNS(s))
                    }
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(it.0).").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted).frame(width: 22, alignment: .trailing)
                        RichText(attr: MD.keNS(it.1))
                    }
                }
            }
        case .table(let head, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) { ForEach(Array(head.enumerated()), id: \.offset) { _, c in
                        Text(MD.ke(c, size: 15, weight: .semibold)) } }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 14) { ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(MD.ke(c, size: 15)) } }
                    }
                }
            }
        }
    }

    private func joined(_ lines: [String]) -> AttributedString {
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(MD.ke(l))
        }
        return out
    }
}

/// 寻的气泡：每个换行即独立段落（仿 A 社），行内 markdown，#标题也认。
struct UserTextView: View {
    let text: String
    var body: some View {
        let paras = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                RichText(attr: MD.xunNS(p))   // 寻定：她的气泡用系统默认；18/1.5 照网页
            }
        }
    }
}


/// 系统文本视图承载富文本：粗体/代码/删除线是真的，长按能精确选字复制（SwiftUI 的 Text 只能整段复制）。
struct RichText: UIViewRepresentable {
    let attr: NSAttributedString
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false; tv.isSelectable = true; tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = [.link]
        tv.linkTextAttributes = [.foregroundColor: Theme.uiScrollTint]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        if !tv.attributedText.isEqual(to: attr) { tv.attributedText = attr }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? (UIScreen.main.bounds.width - 32)
        let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: w, height: h)
    }
}
