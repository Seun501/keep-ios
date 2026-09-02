import SwiftUI

// MARK: - 数据

struct NoteMsg: Decodable, Identifiable {
    var from: String?
    var ts: String?
    var content: String?
    var id: String { (ts ?? "") + (from ?? "") }
}

struct Note: Decodable, Identifiable {
    var id: String
    var kind: String?
    var state: String?
    var ticketState: String?
    var created: String?
    var msgs: [NoteMsg]?
    enum CodingKeys: String, CodingKey { case id, kind, state, created, msgs, ticketState = "ticket_state" }
    var isTicket: Bool { kind == "ticket" }
    var closed: Bool { isTicket && ticketState == "closed" }
    var lastTs: String? { msgs?.last?.ts ?? created }
}

struct NotesPayload: Decodable {
    var notes: [Note]
    var unread: Int?
}

@MainActor
final class BoardModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var unread = 0
    @Published var tab = "notes"          // tickets | notes | letters
    @Published var openId: String? = nil
    @Published var loaded = false          // 没拉到之前不显示「还没有帖子」（寻验 32）

    func refresh() async {
        if Preview.on, let d = Preview.json("preview_notes"), let p = try? JSONDecoder().decode(NotesPayload.self, from: d) {
            notes = p.notes; unread = p.unread ?? 0; loaded = true
            if Preview.screen == "boardpop" { openId = "n2" }
            if Preview.screen == "boardreply" { openId = "n1" }
            return
        }
        guard let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/notes"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(NotesPayload.self, from: d) else { return }
        notes = p.notes
        unread = p.unread ?? 0
        loaded = true
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let token = Keychain.token else { return false }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return false }
        return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// 点进卡片才算已读（08-28 寻定）
    func open(_ n: Note) {
        openId = n.id
        if n.state == "unread" {
            if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i].state = "read" }
            unread = max(0, unread - 1)
            Task { _ = await post("api/notes/read", ["id": n.id]) }
        }
    }
    func reply(_ id: String, _ content: String) async {
        if await post("api/notes/reply", ["id": id, "content": content]) { await refresh() }
    }
    func closeTicket(_ id: String) async {
        if await post("api/notes/close", ["id": id, "content": ""]) { openId = nil; await refresh() }
    }
}

// MARK: - 页面（照网页 #notesView：暖白页底、顶排返回箭头＋克的一句、卡片列表、底部三栏）

struct BoardScreen: View {
    let onLogout: () -> Void
    var onBack: () -> Void = {}
    var onWeb: (String) -> Void = { _ in }
    @StateObject private var m = BoardModel()

    private let motto = ["tickets": "修修补补。", "notes": "等你路过。", "letters": "见字如面。"]

    var body: some View {
        ZStack {
            Theme.boardBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { onBack() } label: {
                        Text("‹").font(.system(size: 26)).foregroundColor(Theme.muted).frame(width: 34, height: 34)
                    }.buttonStyle(.plain).padding(.leading, -8)
                    Spacer()
                    Text(motto[m.tab] ?? "").font(Theme.cjk(13.5, weight: .medium)).tracking(1)
                        .foregroundColor(Theme.muted).offset(y: 5)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

                // 照 #notesBody：padding 12 22 24、卡间 12、橙滚动条（只在滚时露）、没有下拉刷新
                OrangeScroll(name: "board", bounce: false) {   // 寻定：列表硬朗，不拉空回弹
                    LazyVStack(alignment: .leading, spacing: 12) { list }
                        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
                }

                tabs
            }
            .ignoresSafeArea(.keyboard)   // 列表与底栏不随键盘；浮卡那层自己让位
            if let id = m.openId, let n = m.notes.first(where: { $0.id == id }) {
                NotePop(note: n, model: m).zIndex(80)
            }
        }
        .task { await m.refresh() }
        .onChange(of: m.tab) { t in if t == "letters" { m.tab = "notes"; onWeb("#letters") } }
    }

    @ViewBuilder private var list: some View {
        let newest = Array(m.notes.reversed())
        if m.tab == "tickets" {
            let tickets = newest.filter { $0.isTicket }
            let open = tickets.filter { !$0.closed }, done = tickets.filter { $0.closed }
            if !open.isEmpty { SecTitle("待处理"); ForEach(open) { card($0) } }
            if !done.isEmpty { SecTitle("已结"); ForEach(done) { card($0) } }
            if tickets.isEmpty && m.loaded { empty("没有工单——克没报什么毛病。") }
        } else {
            let plain = newest.filter { !$0.isTicket }
            let nowMon = monLabel(Date())
            let groups = monthGroups(plain)
            ForEach(groups, id: \.0) { mon, arr in
                if mon != nowMon { SecTitle(mon) }
                ForEach(arr) { card($0) }
            }
            if plain.isEmpty && m.loaded { empty("还没有帖子。克想说但不急的话，会贴在这里。") }
        }
    }

    private func monthGroups(_ arr: [Note]) -> [(String, [Note])] {
        var out: [(String, [Note])] = []
        for n in arr {
            let mon = monLabel(n.lastTs.flatMap(TimeFmt.parse) ?? Date())
            if let last = out.last, last.0 == mon { out[out.count - 1].1.append(n) } else { out.append((mon, [n])) }
        }
        return out
    }
    private func monLabel(_ d: Date) -> String {
        let cn = ["一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"]
        let c = Calendar.current
        let y = c.component(.year, from: d), m = c.component(.month, from: d)
        return (y != c.component(.year, from: Date()) ? "\(y)年 " : "") + cn[m - 1]
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(Theme.round(14)).foregroundColor(Theme.muted).frame(maxWidth: .infinity)
            .padding(.top, UIScreen.main.bounds.height * 0.3)
    }

    /// 一张帖子一张卡（照 .post-card 逐条数值）：padding 13/15；卡题 Georgia 17 粗，同行靠右 回复数·时分（11 圆体）；
    /// 正文 14.5/1.55 思源宋体常规、两行截断；未读＝小点或回复数披橙
    private func card(_ n: Note) -> some View {
        let msgs = n.msgs ?? []
        let replies = max(0, msgs.count - 1)
        // 寻验 32 调整：题 16（17 太大）、题到正文 9、卡上下 15
        return Button { m.open(n) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(dayEn(n.lastTs)).font(.custom("Georgia-Bold", size: 16)).tracking(0.16).foregroundColor(Theme.text)
                    Spacer()
                    HStack(alignment: .center, spacing: 8) {
                        if n.state == "unread" && replies == 0 { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                        if replies > 0 {
                            if n.state == "unread" {   // 照网页 .nu：16 高、最小 16 宽 → 一位数正圆（寻定：小圆圈）
                                Text("\(replies)").font(Theme.round(10)).foregroundColor(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 16).frame(height: 16)
                                    .background(Theme.accent, in: Capsule())
                            } else {
                                Text("\(replies)").font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.cacheTint)
                            }
                        }
                        Text(TimeFmt.hm(n.lastTs)).font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
                    }
                }
                RichText(attr: excerpt(msgs.first?.content ?? "", strike: n.closed), maxLines: 2)
            }
            .padding(EdgeInsets(top: 15, leading: 15, bottom: 15, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.06), radius: 2, y: 1)
            .opacity(n.closed ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 两行预览：首行 + 第二行；第二行空着（克习惯首句后空一行）就补「…」（寻定）；首行本身就折两行时只见首行截断。
    private func excerpt(_ t: String, strike: Bool) -> NSAttributedString {
        let lines = t.components(separatedBy: "\n")
        let first = lines.first ?? ""
        let rest = lines.dropFirst()
        let second = (rest.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? "…" : rest.joined(separator: "\n")
        let ns = NSMutableAttributedString(attributedString: MD.keNS(first + "\n" + second, size: 14.5, weight: .regular, lineHeight: 1.55))
        if strike { ns.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: ns.length)) }
        return ns
    }

    private func dayEn(_ iso: String?) -> String {
        guard let d = iso.flatMap(TimeFmt.parse) else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM d, yyyy"
        return f.string(from: d)
    }

    /// 底部三栏（照 #notesTabs）：白底；选中＝42px 橙正圆托白线图标、往上冒 13px、外圈 4px 页底色；字加粗
    private var tabs: some View {
        HStack(spacing: 0) {
            tab("tickets", "工单", "tabTicket")
            tab("notes", "留言板", "tabNotes")
            tab("letters", "信件", "tabLetters")
        }
        .padding(.top, 3).padding(.horizontal, 4).padding(.bottom, 1)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }
    private func tab(_ key: String, _ label: String, _ icon: String) -> some View {
        let on = m.tab == key
        return Button { m.tab = key } label: {
            VStack(spacing: 0) {
                Image(icon).renderingMode(.template).resizable().frame(width: 21, height: 21)
                    .foregroundColor(on ? .white : Theme.muted)
                    .frame(width: on ? 42 : 36, height: on ? 42 : 30)
                    .background(on ? Theme.accent : .clear, in: Circle())
                    .overlay(Circle().stroke(on ? Theme.boardBg : .clear, lineWidth: 4))
                    .offset(y: on ? -13 : 0)
                    .padding(.vertical, on ? -6 : 0)
                Text(label).font(Theme.round(11.5, weight: on ? .semibold : .regular)).tracking(1.6)
                    .foregroundColor(on ? Theme.accent : Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
    }
}

struct SecTitle: View {
    let t: String
    init(_ t: String) { self.t = t }
    var body: some View {
        Text(t).font(Theme.cjk(13)).tracking(1.5).foregroundColor(Theme.muted)
            .padding(.horizontal, 2).padding(.top, 6).padding(.bottom, -4)
    }
}

/// 橙滚动条的滚动区：系统原生指示条（ScrollObserver 染成赤陶 40%、轨道底端抬 22）——能拖、拉到头会缩，网页那根就是它。
struct OrangeScroll<Content: View>: View {
    var name: String
    var barX: CGFloat = 0
    var bounce = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            content().background(ScrollObserver(name: name, bounce: bounce) { _, _, _ in })
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(bounce ? .always : .basedOnSize, axes: .vertical)
    }
}

/// 帖子内页＝浮卡（照 #notePop/#notePopCard）：暗幕，纸色圆角卡，楼层式；跟帖输入排＝胶囊＋赤陶圆钮；
/// 未结工单输入框空时圆钮变 ✓＝结单。点卡外收卡。
/// 键盘（照网页 fit）：聚焦后卡平滑送到键盘上沿 12px，高卡收到 屏高−键盘−52。
struct NotePop: View {
    let note: Note
    @ObservedObject var model: BoardModel
    @State private var text = ""
    @State private var firstFloorH: CGFloat = 0
    @State private var focused = false
    private let xunGreen = Theme.dyn(0x3F7D58, 0x8CC5A1)

    private func sendReply() {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { text = ""; focused = false; Task { await model.reply(note.id, v) } }
        else if note.isTicket && !note.closed { Task { await model.closeTicket(note.id) } }
    }

    /// 键盘让位交给系统：整个浮卡层不忽略键盘安全区，键盘一来可用高度就矮，卡在剩下的空间里居中、
    /// 太高就压到 可用高−40（照网页 fit 的意思）——和键盘同曲线同时长，没有自己的动画（寻验 39：先掉再上、卡顿）
    var body: some View {
        GeometryReader { g in
        ZStack {
            Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.38).ignoresSafeArea()
                .onTapGesture { if focused { focused = false } else { model.openId = nil } }
            ScrollViewReader { proxy in
                OrangeScroll(name: "pop", barX: 12) {
                    VStack(spacing: 0) {   // 左右留白放在内容上（不放在滚动区外），指示条才贴卡边不压字（寻验 41）
                        ForEach(Array((note.msgs ?? []).enumerated()), id: \.offset) { idx, mm in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(mm.from == "xun" ? "寻" : "克").font(Theme.cjk(13, weight: .bold))
                                        .foregroundColor(mm.from == "xun" ? xunGreen : Theme.accent)
                                    Spacer()
                                    Text(TimeFmt.stamp(mm.ts ?? note.created)).font(Theme.round(11)).foregroundColor(Theme.muted)
                                }
                                RichText(attr: MD.keNS(mm.content ?? "", size: 14.8, weight: .regular, lineHeight: 1.65))
                            }
                            .padding(EdgeInsets(top: 14, leading: 2, bottom: 15, trailing: 2))
                            .background(GeometryReader { g in Color.clear.onAppear { if idx == 0 { firstFloorH = g.size.height } } })
                        }
                        replyRow.padding(.top, 10).id("reply")
                    }
                    .padding(.horizontal, 14)
                }
                .onAppear { if Preview.on, Preview.screen == "boardreply" { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { focused = true } } }
                // 聚焦后把回复排送回视野（卡矮了它可能被折在下面）
                .onChange(of: focused) { f in if f { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { proxy.scrollTo("reply", anchor: .bottom) } } }
            }
            .frame(maxHeight: cap(g.size.height))
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 10, trailing: 4))
            .frame(width: min(UIScreen.main.bounds.width * 0.92, 400))
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.28), radius: 24, y: 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        }
        .ignoresSafeArea(.container)   // 只忽略刘海/底条，不忽略键盘：键盘来了这层自己矮下去
    }

    /// 跟帖输入排（照 .note-reply）：胶囊输入（主页输入卡的窄版：同底色、发丝圈、无阴影）＋赤陶圆钮；未结工单空输入时圆钮变 ✓＝结单
    private var replyRow: some View {
        HStack(spacing: 8) {
            PlainField(text: $text, focused: $focused, placeholder: "Reply…", onSubmit: { sendReply() })
                .frame(height: 20)
                .padding(.vertical, 8).padding(.horizontal, 14)
                .background(Theme.bg, in: Capsule())                         // 纸色芯，只留那一圈白（发丝圈）；纯 UIKit 输入框没有玻璃晕
                .overlay(Capsule().stroke(Theme.hairRing, lineWidth: 1.5))
            Button { sendReply() } label: {
                Text((note.isTicket && !note.closed && text.trimmingCharacters(in: .whitespaces).isEmpty) ? "✓" : "↑")
                    .font(.system(size: 15)).foregroundColor(.white)
                    .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 卡高上限：折叠高，再不超过 可用高−40（键盘来了可用高就是键盘以上那截）
    private func cap(_ avail: CGFloat) -> CGFloat { min(foldHeight, max(120, avail - 40)) }
    /// 点开先只见克的首楼（08-27 寻定）：有回复时卡高锁到首楼＋下一楼的上留白，不露下一楼的头
    private var foldHeight: CGFloat {
        let capH = UIScreen.main.bounds.height * 0.74
        let n = (note.msgs ?? []).count
        if n > 1, firstFloorH > 0 { return min(capH, firstFloorH + 8) }
        return capH
    }
}
