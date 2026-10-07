import SwiftUI

// MARK: - 记忆页「主文件」栏（寻 10-05 样稿第十稿）
// 列表：常驻 / 路径为主 / 其余三段，卡片照注入栏（衬线名＋右边 Mono 字数，不加千位逗号）。
// 点开整页推进来（字多，不用下拉也不用白笺）：「现在是这样」全列，「以前 → 后来」不折、空开一截、字调灰。
// 行尾出处：「桶」赤陶可点＝浮起那张桶卡（读完点暗处收起，不离开这页）；「#N」赤陶可点＝去档案馆那一条；
// 其余出处（旧便签 L12、叙事搬来……）像素小灰字只看。

struct MastersPayload: Decodable {
    struct F: Decodable { var name: String; var chars: Int; var tag: String }
    var files: [F]
}

struct MasterDoc: Decodable {
    struct Cite: Decodable { var bucket: String?; var nos: [Int]?; var days: [String]?; var label: String? }
    struct Line: Decodable { var kind: String; var text: String; var cite: [Cite] }
    var name: String
    var now: [Line]
    var past: [Line]
}

@MainActor
final class MastersModel: ObservableObject {
    @Published var files: [MastersPayload.F]? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_masters"), let p = try? JSONDecoder().decode(MastersPayload.self, from: d) { files = p.files } else { failed = true }
            return
        }
        if files == nil, let c = NetCache.load("api/masters"), let p = try? JSONDecoder().decode(MastersPayload.self, from: c) { files = p.files }
        guard let (d, code) = await MemAPI.call("api/masters"), code == 200,
              let p = try? JSONDecoder().decode(MastersPayload.self, from: d) else { failed = files == nil; return }
        if NetCache.save("api/masters", d) || files == nil { files = p.files }
        failed = false
    }
    func doc(_ name: String) async -> MasterDoc? {
        if Preview.on { return Preview.json("preview_master_doc").flatMap { try? JSONDecoder().decode(MasterDoc.self, from: $0) } }
        guard let (d, code) = await MemAPI.call("api/masters/" + name), code == 200 else {   // 没连上就拿上次存的
            return NetCache.load("api/masters/" + name).flatMap { try? JSONDecoder().decode(MasterDoc.self, from: $0) }
        }
        NetCache.save("api/masters/" + name, d)
        return try? JSONDecoder().decode(MasterDoc.self, from: d)
    }
}

struct MastersTab: View {
    @ObservedObject var m: MastersModel
    var onOpen: (String) -> Void

    var body: some View {
        if m.failed { MemEmpty("没拿到主文件，退出来再进一次试试") }
        else if let fs = m.files {
            ForEach(["常驻", "路径为主", "其余"], id: \.self) { tag in
                let arr = fs.filter { $0.tag == tag }
                if !arr.isEmpty {
                    SecTitle(tag)
                    ForEach(arr, id: \.name) { f in
                        Button { onOpen(f.name) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(f.name).font(Theme.georgiaCJK(16)).foregroundColor(Theme.text)
                                Spacer(minLength: 6)
                                (Text(verbatim: String(f.chars)).font(Theme.mono(10)) + Text(" 字").font(Theme.cjk(10.5)))
                                    .foregroundColor(Theme.muted)
                                Text("›").font(Theme.cjk(13)).foregroundColor(Theme.muted)
                            }
                            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card).shadow(color: Theme.text.opacity(0.06), radius: 1, y: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else { MemEmpty("加载中…") }
    }
}

/// 整页（盖住记忆页和底栏，左上 ‹ 返回）
struct MasterPage: View {
    let name: String
    @ObservedObject var m: MastersModel
    @ObservedObject var buckets: BucketsModel
    var onBack: () -> Void
    var onArchive: (String, Int) -> Void
    @State private var doc: MasterDoc? = nil
    @State private var failed = false
    @State private var peek: BucketsPayload.B? = nil

    var body: some View {
        ZStack {
            Theme.boardBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { onBack() } label: { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Text(name).font(Theme.georgiaCJK(17)).foregroundColor(Theme.text).lineLimit(1)
                    Spacer()
                    if let c = m.files?.first(where: { $0.name == name })?.chars {
                        (Text(verbatim: String(c)).font(Theme.mono(10)) + Text(" 字").font(Theme.cjk(10.5))).foregroundColor(Theme.muted)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                OrangeScroll(name: "master-" + name) {
                    VStack(alignment: .leading, spacing: 0) {
                        if failed { MemEmpty("没拿到这份，退出来再进一次试试") }
                        else if let d = doc {
                            head("现在是这样")
                            ForEach(Array(d.now.enumerated()), id: \.offset) { _, l in line(l, past: false) }
                            if !d.past.isEmpty {
                                head("以前 → 后来").padding(.top, 30)
                                ForEach(Array(d.past.enumerated()), id: \.offset) { _, l in line(l, past: true) }
                            }
                        } else { MemEmpty("加载中…") }
                    }
                    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 30)
                }
            }
            if let b = peek {
                Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.32).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { peek = nil } }
                BucketCard(b: b, isOpen: true, pop: true, onArchive: { d, n in peek = nil; onArchive(d, n) })
                    .shadow(color: Theme.text.opacity(0.18), radius: 16, y: 8)
                    .frame(width: min(UIScreen.main.bounds.width * 0.92, 400))   // 照留言板浮卡的宽
                    .transition(.opacity)
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .environment(\.openURL, OpenURLAction { url in
            let parts = url.pathComponents.filter { $0 != "/" }
            if url.host == "bucket", let id = parts.first {
                if let b = buckets.items?.first(where: { $0.id == id }) { withAnimation(.easeOut(duration: 0.2)) { peek = b } }
            } else if url.host == "no", parts.count == 2, let n = Int(parts[1]), !parts[0].isEmpty {
                onArchive(parts[0], n)
            }
            return .handled
        })
        .task {
            if buckets.items == nil { await buckets.load() }
            if let d = await m.doc(name) { doc = d } else { failed = true }
            if Preview.on && Preview.screen == "memmfpeek" { peek = buckets.items?.first(where: { $0.id == "p2" }) }
        }
    }

    private func head(_ t: String) -> some View {
        Text(t).font(Theme.cjk(13)).tracking(0.5).foregroundColor(Theme.muted).padding(.bottom, 10)
    }

    @ViewBuilder private func line(_ l: MasterDoc.Line, past: Bool) -> some View {
        if l.kind == "h" {
            Text(l.text).font(Theme.cjk(13, weight: .semibold)).foregroundColor(Theme.muted).padding(.top, 8).padding(.bottom, 6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if l.kind == "li" { Circle().fill(Theme.muted).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 } }
                Text(attributed(l, past: past)).tint(Theme.accent).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 8)
        }
    }

    /// 出处整块不许从中间折行（「旧便签 L12」曾折成「旧便」/「签 L12」）：字与字之间塞零宽连字符、空格换不断行空格
    private func glue(_ t: String) -> String {
        t.map { $0 == " " ? "\u{00A0}" : String($0) }.joined(separator: "\u{2060}")
    }

    /// 正文＋行尾出处拼成一段：桶 / #N 是链接（赤陶、点了走 openURL），别的出处像素小灰字
    private func attributed(_ l: MasterDoc.Line, past: Bool) -> AttributedString {
        var s = AttributedString(l.text)
        s.font = Font(Theme.uiSerif(14.8))
        s.foregroundColor = past ? Theme.muted : Theme.text
        for c in l.cite {
            if let id = c.bucket {
                var r = AttributedString("  桶")
                r.font = Font(Theme.uiPixel(12))
                r.foregroundColor = Theme.accent
                r.link = URL(string: "keepref://bucket/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id))
                s += r
            }
            for (i, n) in (c.nos ?? []).enumerated() {
                let day = (c.days ?? []).indices.contains(i) ? c.days![i] : ""
                var r = AttributedString("  " + glue("#\(n)"))
                r.font = Font(Theme.uiMono(11))
                r.foregroundColor = day.isEmpty ? Theme.muted : Theme.accent
                if !day.isEmpty { r.link = URL(string: "keepref://no/\(day)/\(n)") }
                s += r
            }
            if let lb = c.label, lb != "原文" {
                var r = AttributedString("  " + glue(lb))
                r.font = Font(Theme.uiPixel(12))
                r.foregroundColor = Theme.muted
                s += r
            }
        }
        return s
    }
}
