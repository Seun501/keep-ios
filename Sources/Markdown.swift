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
            Text(joined(lines)).font(Theme.serif(18, weight: .medium)).lineSpacing(6).foregroundColor(Theme.text)
        case .heading(let lv, let s):
            Text(MD.inline(s)).font(Theme.serif(lv <= 2 ? 21 : 18.5, weight: .semibold)).foregroundColor(Theme.text)
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(.system(size: 13.5, design: .monospaced)).foregroundColor(Theme.text)
                    .padding(10)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let q):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.border).frame(width: 2)
                Text(joined(q)).font(Theme.serif(18, weight: .medium)).lineSpacing(6).foregroundColor(Theme.muted)
            }
        case .ul(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted)
                        Text(MD.inline(s)).font(Theme.serif(18, weight: .medium)).lineSpacing(6).foregroundColor(Theme.text)
                    }
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(it.0).").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted)
                        Text(MD.inline(it.1)).font(Theme.serif(18, weight: .medium)).lineSpacing(6).foregroundColor(Theme.text)
                    }
                }
            }
        case .table(let head, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) { ForEach(Array(head.enumerated()), id: \.offset) { _, c in
                        Text(MD.inline(c)).font(Theme.serif(15, weight: .semibold)).foregroundColor(Theme.text) } }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 14) { ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(MD.inline(c)).font(Theme.serif(15)).foregroundColor(Theme.text) } }
                    }
                }
            }
        }
    }

    private func joined(_ lines: [String]) -> AttributedString {
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(MD.inline(l))
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
                Text(MD.inline(p)).font(Theme.serif(18)).lineSpacing(4).foregroundColor(Theme.text)
            }
        }
    }
}
