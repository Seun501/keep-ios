import SwiftUI

// MARK: - 记忆页「词条」「日子」两栏（样式寻 10-01 过目：临时给寻\词条页样式.html；10-04 接线）
// 词条＝主文件〔关键词〕小节里的「- 名字：说明」，她提到名字时那一行递给克；寻能改、加、删（写回主文件，页尾记「寻 改」）。
// 日子＝早安卡提前三天开始提的那些：快到的 / 约好的 / 每年的；dates.json 里的能增删，系统算的只看。

struct WordsPayload: Decodable {
    struct Item: Decodable { var names: [String]; var desc: String; var cite: String?; var line: String }
    struct Sec: Decodable { var title: String; var items: [Item] }
    struct Group: Decodable { var file: String; var sections: [Sec] }
    var files: [String]?
    var groups: [Group]
}

struct DatesPayload: Decodable {
    struct Row: Decodable {
        var date: String; var spec: String; var title: String; var src: String?; var editable: Bool; var left: Int
        var key: String { "d-\(spec)-\(title)" }
    }
    var soon: [Row]
    var planned: [Row]
    var yearly: [Row]
}

/// 记忆页三栏共用的小请求：回 (数据, 状态码)；网关回 {"detail": "…"} 的错误话直接给她看
enum MemAPI {
    static func call(_ path: String, _ body: [String: Any]? = nil) async -> (Data, Int)? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let b = body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return nil }
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
    static func detail(_ d: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["detail"] as? String
    }
}

@MainActor
final class WordsModel: ObservableObject {
    @Published var data: WordsPayload? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_words"), let p = try? JSONDecoder().decode(WordsPayload.self, from: d) { data = p } else { failed = true }
            return
        }
        guard let (d, code) = await MemAPI.call("api/words"), code == 200,
              let p = try? JSONDecoder().decode(WordsPayload.self, from: d) else { failed = data == nil; return }
        data = p; failed = false
    }
    /// 存/删：成功回 nil（列表用回包刷新）；失败回给她看的一句话
    func send(_ body: [String: Any]) async -> String? {
        if Preview.on { return "预览里不真存" }
        guard let (d, code) = await MemAPI.call("api/words", body) else { return "没连上，再试一次" }
        if code == 200 {
            if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let g = j["groups"],
               let gd = try? JSONSerialization.data(withJSONObject: ["files": data?.files ?? [], "groups": g]),
               let p = try? JSONDecoder().decode(WordsPayload.self, from: gd) { data = p } else { await load() }
            return nil
        }
        if code == 409 { await load() }
        return MemAPI.detail(d) ?? "没存上（\(code)）"
    }
}

@MainActor
final class DatesModel: ObservableObject {
    @Published var data: DatesPayload? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_dates"), let p = try? JSONDecoder().decode(DatesPayload.self, from: d) { data = p } else { failed = true }
            return
        }
        guard let (d, code) = await MemAPI.call("api/dates"), code == 200,
              let p = try? JSONDecoder().decode(DatesPayload.self, from: d) else { failed = data == nil; return }
        data = p; failed = false
    }
    func send(_ body: [String: Any]) async -> String? {
        if Preview.on { return "预览里不真存" }
        guard let (d, code) = await MemAPI.call("api/dates", body) else { return "没连上，再试一次" }
        if code == 200, let p = try? JSONDecoder().decode(DatesPayload.self, from: d) { data = p; return nil }
        if code == 404 { await load() }
        return MemAPI.detail(d) ?? "没存上（\(code)）"
    }
}

// MARK: - 词条栏

struct WordDraft: Identifiable {
    var id = UUID()
    var file: String
    var section = ""
    var names = ""
    var desc = ""
    var old: (file: String, line: String)? = nil
}

struct WordsTab: View {
    @ObservedObject var m: WordsModel
    var onEdit: (WordDraft) -> Void
    var body: some View {
        if m.failed { MemEmpty("没拿到词条，退出来再进一次试试") }
        else if let d = m.data {
            if d.groups.isEmpty {
                SecTitle("词条", right: "＋", onRight: { onEdit(WordDraft(file: d.files?.first ?? "")) })
                MemEmpty("还没有词条。克批过的改动单会把「名字：说明」写进来，你也可以点 ＋ 自己加。", top: 0.2)
            }
            ForEach(d.groups, id: \.file) { g in
                SecTitle(g.file, right: "＋", onRight: { onEdit(WordDraft(file: g.file, section: g.sections.first?.title ?? "")) })
                ForEach(g.sections, id: \.title) { s in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(s.title).font(Theme.georgiaCJK(16)).foregroundColor(Theme.text)
                            Spacer()
                            Text("\(s.items.count) 条").font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
                        }
                        .padding(.bottom, 2)
                        ForEach(Array(s.items.enumerated()), id: \.element.line) { i, it in
                            row(it).padding(.top, 9).padding(.bottom, 10)
                                .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 0.5) } }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onEdit(WordDraft(file: g.file, section: s.title, names: it.names.joined(separator: " / "),
                                                     desc: it.desc, old: (g.file, it.line)))
                                }
                        }
                    }
                    .padding(EdgeInsets(top: 13, leading: 15, bottom: 3, trailing: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
                }
            }
        } else { MemEmpty("加载中…") }
    }
    private func row(_ it: WordsPayload.Item) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(it.names.first ?? "").font(Theme.cjk(15, weight: .semibold)).foregroundColor(Theme.text)
                if it.names.count > 1 {
                    Text("/ " + it.names.dropFirst().joined(separator: " / ")).font(Theme.cjk(12)).foregroundColor(Theme.muted)
                }
            }
            Text(it.desc).font(Theme.cjk(13)).lineSpacing(3).foregroundColor(Theme.text.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            if let c = it.cite, !c.isEmpty {
                Text(c).font(Theme.round(11)).foregroundColor(Theme.muted).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 日子栏

struct DatesTab: View {
    @ObservedObject var m: DatesModel
    var onAdd: () -> Void
    @State private var swiped: String? = nil   // 左滑露出「删除」的那一行（同时只开一行）
    @State private var err: String? = nil
    var body: some View {
        if m.failed { MemEmpty("没拿到日子，退出来再进一次试试") }
        else if let d = m.data {
            if !d.soon.isEmpty {
                SecTitle("快到的")
                card(d.soon, pill: true, deletable: false)
            }
            SecTitle("约好的", right: "＋", onRight: onAdd)
            if d.planned.isEmpty {
                Text("还没有，点 ＋ 加一个").font(Theme.cjk(13)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15))
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
            } else { card(d.planned, pill: true, deletable: true) }
            if !d.yearly.isEmpty {
                SecTitle("每年的")
                card(d.yearly, pill: false, deletable: true)
            }
            if let e = err { Text(e).font(Theme.cjk(12)).foregroundColor(Theme.muted).padding(.horizontal, 2) }
        } else { MemEmpty("加载中…") }
    }
    private func card(_ rows: [DatesPayload.Row], pill: Bool, deletable: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.key) { i, r in
                let line = dayRow(r, pill: pill)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 0.5).padding(.horizontal, 15) } }
                if deletable && r.editable {
                    SwipeDelete(open: Binding(get: { swiped == r.key }, set: { swiped = $0 ? r.key : nil })) {
                        line
                    } onDelete: {
                        Task { err = await m.send(["op": "delete", "date": r.spec, "title": r.title]); swiped = nil }
                    }
                } else { line }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }
    private func dayRow(_ r: DatesPayload.Row, pill: Bool) -> some View {
        let parts = r.date.split(separator: "-")
        let mo = parts.count == 3 ? Int(parts[1]) ?? 0 : 0
        let dd = parts.count == 3 ? Int(parts[2]) ?? 0 : 0
        let src = (r.src ?? "").isEmpty ? (r.editable ? "约好的" : "系统算的") : r.src!
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(mo)月").font(Theme.cjk(11)).foregroundColor(Theme.muted)
                Text("\(dd)").font(.custom("Georgia-Bold", size: 17)).foregroundColor(Theme.text)
            }
            .frame(width: 52, alignment: .trailing)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.title).font(Theme.cjk(15)).foregroundColor(Theme.text).lineLimit(1)
                Text(src).font(Theme.cjk(11)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if pill {
                Text(r.left == 0 ? "就是今天" : "还有 \(r.left) 天").font(Theme.cjk(12))
                    .foregroundColor(r.left == 0 ? Theme.knockText : MemColor.xun)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(r.left == 0 ? Theme.knockBg : MemColor.softXun, in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 15)
        .background(Theme.card)
    }
}

enum MemColor {
    static let xun = Theme.dyn(0x2F5D45, 0x8CC5A1)       // 寻的松绿（样式稿 --xun）
    static let softXun = Theme.dyn(0xE5EBE3, 0x2B3530)
}

/// 左滑露出「删除」（淡赤陶底朱砂字，不描边）；不挡竖向滚动——只认横向为主的拖动
struct SwipeDelete<Content: View>: View {
    @Binding var open: Bool
    @ViewBuilder var content: () -> Content
    var onDelete: () -> Void
    @State private var drag: CGFloat = 0
    private let w: CGFloat = 76
    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                Text("删除").font(Theme.cjk(13.5)).foregroundColor(Theme.knockText)
                    .frame(width: w).frame(maxHeight: .infinity).background(Theme.knockBg)
            }
            .buttonStyle(.plain)
            .opacity(open || drag < 0 ? 1 : 0)
            content()
                .offset(x: min(0, max(-w - 20, (open ? -w : 0) + drag)))
                .simultaneousGesture(DragGesture(minimumDistance: 14).onChanged { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    drag = v.translation.width
                }.onEnded { v in
                    if abs(v.translation.width) > abs(v.translation.height) {
                        withAnimation(.easeOut(duration: 0.2)) { open = (open ? -w : 0) + v.translation.width < -w / 2; drag = 0 }
                    } else { drag = 0 }
                })
                .onTapGesture { if open { withAnimation(.easeOut(duration: 0.2)) { open = false } } }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MemEmpty: View {
    let t: String
    var top: CGFloat = 0.3
    init(_ t: String, top: CGFloat = 0.3) { self.t = t; self.top = top }
    var body: some View {
        Text(t).font(Theme.cjk(14)).foregroundColor(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
            .frame(maxWidth: .infinity).padding(.top, UIScreen.main.bounds.height * top)
    }
}

// MARK: - 底下升起的白笺（样式稿 ④）：暗幕、抓手、居中题；盖住底栏；键盘来了整张往上让

struct MemSheet<Content: View>: View {
    var title: String
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.32).ignoresSafeArea()
                    .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); onClose() }
                VStack(spacing: 0) {
                    Capsule().fill(Theme.border).frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
                    Text(title).font(Theme.cjk(16, weight: .semibold)).foregroundColor(Theme.text).padding(.bottom, 14)
                    OrangeScroll(name: "memsheet", bounce: false) { content().padding(.horizontal, 20).padding(.bottom, 30) }   // 赤陶滚动条（寻 10-04）；bounce:false＝内容不满不回弹，同原来
                        .frame(maxHeight: max(160, g.size.height - 120))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
                .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

struct MemField<Content: View>: View {
    var label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(Theme.cjk(12)).foregroundColor(Theme.muted).padding(.leading, 2).padding(.bottom, 5)
            content()
            if let h = hint { Text(h).font(Theme.cjk(11)).foregroundColor(Theme.muted).padding(.leading, 2).padding(.top, 5) }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MemChip: View {
    let t: String
    let on: Bool
    var tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Text(t).font(Theme.cjk(12)).foregroundColor(on ? MemColor.xun : Theme.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? MemColor.softXun : Theme.panel, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 输入框底（淡纸色圆角块，不描边）
private struct InputBox: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.vertical, 10).padding(.horizontal, 12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct WordSheet: View {
    @ObservedObject var m: WordsModel
    @State var d: WordDraft
    var onClose: () -> Void
    @State private var fSec = false
    @State private var fName = false
    @FocusState private var fDesc: Bool
    @State private var busy = false
    @State private var err: String? = nil
    @State private var sureDel = false

    var body: some View {
        MemSheet(title: d.old == nil ? "新词条" : "编辑词条", onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                MemField(label: "归在哪份主文件") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(m.data?.files ?? [d.file], id: \.self) { f in MemChip(t: f, on: d.file == f) { d.file = f } }
                        }
                    }
                }
                MemField(label: "哪一类") {
                    PlainField(text: $d.section, focused: $fSec, placeholder: "护肤、同学、常去的店…", font: Theme.uiSys(14), returnKey: .next,
                               onSubmit: { fName = true })
                        .frame(height: 18).modifier(InputBox())
                    let secs = (m.data?.groups.first(where: { $0.file == d.file })?.sections ?? []).map(\.title).filter { $0 != d.section }
                    if !secs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(secs, id: \.self) { s in MemChip(t: s, on: false) { d.section = s } } }
                        }
                        .padding(.top, 6)
                    }
                }
                MemField(label: "名字", hint: "几个叫法用 / 隔开；她说到其中一个，这一行就递给克") {
                    PlainField(text: $d.names, focused: $fName, placeholder: "理肤泉 / B5", font: Theme.uiSys(14), returnKey: .next,
                               onSubmit: { fDesc = true })
                        .frame(height: 18).modifier(InputBox())
                }
                MemField(label: "说明") {
                    TextField("", text: $d.desc, axis: .vertical)
                        .font(Theme.ui(14)).foregroundColor(Theme.text).lineLimit(2...6)
                        .focused($fDesc).tint(Theme.scrollTint)
                        .frame(minHeight: 42, alignment: .topLeading).modifier(InputBox())
                }
                if let e = err { Text(e).font(Theme.cjk(12)).foregroundColor(Theme.knockText).padding(.leading, 2).padding(.bottom, 4) }
                HStack(spacing: 10) {
                    if d.old != nil {
                        Button { delete() } label: {
                            Text(sureDel ? "确定删？" : "删除").font(Theme.cjk(14)).foregroundColor(Theme.knockText)
                                .frame(width: 84).padding(.vertical, 11)
                                .background(Theme.knockBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain).disabled(busy)
                    }
                    Button { save() } label: {
                        Text(busy ? "…" : "保存").font(Theme.cjk(14)).foregroundColor(Theme.card)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.text, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
                .padding(.top, 6)
            }
        }
    }
    private func unfocus() { fSec = false; fName = false; fDesc = false }
    private func save() {
        unfocus(); busy = true; err = nil
        var body: [String: Any] = ["op": "save", "file": d.file, "section": d.section, "names": d.names, "desc": d.desc]
        if let o = d.old { body["old"] = ["file": o.file, "line": o.line] }
        Task {
            err = await m.send(body); busy = false
            if err == nil { onClose() }
        }
    }
    private func delete() {
        guard let o = d.old else { return }
        if !sureDel { sureDel = true; return }
        unfocus(); busy = true; err = nil
        Task {
            err = await m.send(["op": "delete", "file": o.file, "line": o.line]); busy = false
            if err == nil { onClose() }
        }
    }
}

struct DaySheet: View {
    @ObservedObject var m: DatesModel
    var onClose: () -> Void
    @State private var title = ""
    @State private var day = Date()
    @State private var yearly = false
    @State private var fTitle = false
    @State private var busy = false
    @State private var err: String? = nil
    var body: some View {
        MemSheet(title: "新日子", onClose: onClose) {
            VStack(alignment: .leading, spacing: 0) {
                MemField(label: "是什么日子") {
                    PlainField(text: $title, focused: $fTitle, placeholder: "去青羊宫、交论文…", font: Theme.uiSys(14), returnKey: .done,
                               onSubmit: { fTitle = false })
                        .frame(height: 18).modifier(InputBox())
                }
                MemField(label: "哪天") {
                    HStack {
                        DatePicker("", selection: $day, displayedComponents: .date).labelsHidden()
                            .environment(\.locale, Locale(identifier: "zh_CN")).tint(Theme.accent)
                        Spacer()
                    }
                }
                MemField(label: "多久一次", hint: "约好的过了就不再提；每年的年年提前三天提") {
                    HStack(spacing: 6) {
                        MemChip(t: "只这一次", on: !yearly) { yearly = false }
                        MemChip(t: "每年", on: yearly) { yearly = true }
                    }
                }
                if let e = err { Text(e).font(Theme.cjk(12)).foregroundColor(Theme.knockText).padding(.leading, 2).padding(.bottom, 4) }
                Button { save() } label: {
                    Text(busy ? "…" : "保存").font(Theme.cjk(14)).foregroundColor(Theme.card)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(busy).padding(.top, 6)
            }
        }
    }
    private func save() {
        fTitle = false; busy = true; err = nil
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = yearly ? "MM-dd" : "yyyy-MM-dd"
        Task {
            err = await m.send(["op": "add", "date": f.string(from: day), "title": title]); busy = false
            if err == nil { onClose() }
        }
    }
}
