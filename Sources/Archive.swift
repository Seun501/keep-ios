import SwiftUI

// MARK: - 档案馆（正史按天；检索命中；#N 直跳；条数开关）

struct ArchEntry: Decodable, Identifiable {
    var role: String?
    var text: String?
    var thinking: String?
    var ts: String?
    var images: [String]?
    var note: String?
    var diary: Bool?
    var author: String?
    var meal: Bool?
    var sleepNote: Bool?
    var napNote: Bool?
    var rainNote: Bool?
    var placeNote: Bool?
    var wake: Bool?
    var no: Int?
    var thinkSecs: Double?
    var voice: Voice?          // 语音条（09-14）：档案里也能放
    enum CodingKeys: String, CodingKey {
        case role, text, thinking, ts, images, note, diary, author, meal, wake, no, voice
        case sleepNote = "sleep_note", napNote = "nap_note", rainNote = "rain_note", placeNote = "place_note", thinkSecs = "think_secs"
    }
    var id: String { "\(no ?? 0)-\(ts ?? "")-\(role ?? "")" }
    var hm: String { TimeFmt.hm(ts) }
    var isPing: Bool { meal == true || sleepNote == true || napNote == true || rainNote == true || placeNote == true }
}
struct ArchDay: Decodable { var date: String; var entries: [ArchEntry] }
struct ArchHit: Decodable, Identifiable {
    var date: String; var time: String; var who: String?; var snippet: String?; var think: Bool?
    var dayMore: Int?
    enum CodingKeys: String, CodingKey { case date, time, who, snippet, think, dayMore = "day_more" }
    var id: String { date + time + (snippet ?? "").prefix(20) }
}
struct ArchSearch: Decodable { var hits: [ArchHit]?; var truncated: Bool?; var nextBefore: String?
    enum CodingKeys: String, CodingKey { case hits, truncated, nextBefore = "next_before" } }

@MainActor
final class ArchiveModel: ObservableObject {
    @Published var day: ArchDay? = nil
    @Published var hits: [ArchHit] = []
    @Published var q = ""
    @Published var truncated = false
    @Published var nextBefore = ""
    @Published var view: String? = nil       // "day" | "hits"
    @Published var focusNo: Int? = nil
    @Published var focusTime: String? = nil
    @Published var showNums = false
    @Published var flashNo: Int? = nil
    /// 档案馆有记录的日子（和抽屉月历同一份缓存，进门先用旧的、后台再拉新）——前一天/后一天只在这些日子之间跳
    @Published var days: [String] = Preview.on ? [] : (UserDefaults.standard.stringArray(forKey: "cache.days") ?? [])

    private func get(_ path: String) async -> Data? {
        guard let token = Keychain.token else { return nil }
        // 带 ?q= 的搜索地址不能走 appendingPathComponent——它把 ? 编成 %3F 当路径，服务器答 404（09-12 寻验：关键词搜索坏了；同 Books 09-04 那坑）
        let url: URL = path.contains("?") ? (URL(string: path, relativeTo: Gateway.home)?.absoluteURL ?? Gateway.home.appendingPathComponent(path))
                                          : Gateway.home.appendingPathComponent(path)
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
    func loadDays() async {
        if Preview.on { days = ["2026-08-20", "2026-08-28", "2026-09-01", "2026-09-02"]; return }
        guard let d = await get("api/archive/days"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["days"] as? [[String: Any]] else { return }
        days = arr.compactMap { $0["date"] as? String }
        UserDefaults.standard.set(days, forKey: "cache.days")
    }
    /// 前一天（dir=-1）/后一天（+1）：当前这天在表里就取邻居；不在（表旧了）就取最近的一天；到头了＝nil
    func neighbor(_ dir: Int) -> String? {
        guard let cur = day?.date, view == "day" else { return nil }
        if let i = days.firstIndex(of: cur) {
            let j = i + dir
            return (j >= 0 && j < days.count) ? days[j] : nil
        }
        return dir < 0 ? days.last(where: { $0 < cur }) : days.first(where: { $0 > cur })
    }
    func step(_ dir: Int) async {
        guard let d = neighbor(dir) else { return }
        await openDay(d)
    }
    func openDay(_ d: String, time: String? = nil, no: Int? = nil) async {
        let data: Data?
        if Preview.on { data = Preview.json("preview_arch") } else { data = await get("api/archive/day/\(d)") }
        guard let data, let p = try? JSONDecoder().decode(ArchDay.self, from: data) else { return }
        day = p; view = "day"; focusTime = time; focusNo = no
        if let no { flashNo = no; DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { self.flashNo = nil } }
    }
    /// 搜：#N＝正史全局条数直跳；more＝接着上次的结果往更早翻
    func search(_ query: String, more: Bool = false) async {
        let qq = more ? q : query.trimmingCharacters(in: .whitespaces)
        guard !qq.isEmpty else { return }
        if !more, let n = Int(qq.dropFirst()), qq.hasPrefix("#") {
            if Preview.on { await openDay("2026-09-02", no: n); return }
            if let d = await get("api/msgno/\(n)"), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let day = j["day"] as? String { await openDay(day, time: j["hm"] as? String, no: n); return }
        }
        var path = "api/archive/search?q=" + (qq.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? qq)
        if more, !nextBefore.isEmpty { path += "&before=" + nextBefore }
        let data: Data?
        if Preview.on { data = Preview.json("preview_hits") } else { data = await get(path) }
        guard let data, let p = try? JSONDecoder().decode(ArchSearch.self, from: data) else { return }
        if more { hits += p.hits ?? [] } else { q = qq; hits = p.hits ?? [] }
        truncated = p.truncated ?? false; nextBefore = p.nextBefore ?? ""
        view = "hits"
    }
}

struct ArchiveScreen: View {
    var onBack: () -> Void
    var day: String? = nil
    var query: String? = nil
    var focusNo: Int? = nil
    @StateObject private var m = ArchiveModel()
    @State private var markIdx = -1

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                head
                if m.view == "day", let d = m.day { dayView(d) }
                else if m.view == "hits" { hitsView }
                else { Spacer() }
            }
        }
        .background(EdgeSwipe(onBack: back))
        .task {
            if Preview.on, let q = query, let day { await m.search(q); await m.openDay(day) }   // 截图 archq：带关键词进天页
            else if let q = query { await m.search(q) }
            else if let day { await m.openDay(day, no: focusNo) }
            else if Preview.on { await m.openDay("2026-09-02") }
            await m.loadDays()
        }
    }

    /// 前一天/后一天（寻 09-13：翻天不用退出去重进月历）：细箭头贴在日期两侧（同族 Lucide 箭头转向，比返回键小一号）；到头那边淡掉
    private func dayArrow(_ dir: Int) -> some View {
        let on = m.neighbor(dir) != nil
        return Button {
            guard on else { return }
            markIdx = -1
            Task { await m.step(dir) }
        } label: {
            Image("chev").renderingMode(.template).resizable().frame(width: 14, height: 14)
                .rotationEffect(.degrees(dir < 0 ? 90 : -90))
                .foregroundColor(Theme.muted.opacity(on ? 1 : 0.3))
                .frame(width: 30, height: 30)
        }.buttonStyle(.plain)
    }

    /// 从某一天返回：若是从搜索结果进来的，先回到结果列表；否则关闭档案页
    private func back() {
        if m.view == "day", !m.hits.isEmpty { m.view = "hits"; markIdx = -1 } else { onBack() }
    }

    /// 天页：日期居中、两侧细箭头翻前一天/后一天（寻 09-13：箭头放日期旁边好看；离左上角的返回键远，不混）
    private var head: some View {
        ZStack {
            HStack(spacing: 12) {
                Button { back() } label: { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                if m.view == "hits" {
                    Text("搜「\(m.q)」· \(m.hits.count)\(m.truncated ? "+" : "") 处").font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
                }
                Spacer()
                // 命中逐处跳转原来是顶栏里的「▲ 2/5 ▼」（寻 09-21：挤在日期旁边不好看）→ 挪到天页右下角的小胶囊（hitPill）
                if m.view == "day" {   // 条数开关（08-31 寻定）：点亮＝每条尾巴挂全局编号
                    Button { m.showNums.toggle() } label: {
                        Text("#").font(.custom("Georgia", size: 15)).foregroundColor(m.showNums ? Theme.accent : Theme.muted).frame(width: 30, height: 30)
                    }.buttonStyle(.plain)
                }
            }
            if m.view == "day" {
                HStack(spacing: 2) {
                    dayArrow(-1)
                    Text(m.day?.date ?? "").font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
                    dayArrow(1)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: 天页＝和聊天一模一样的排版
    private func dayView(_ d: ArchDay) -> some View {
        ScrollViewReader { proxy in
            OrangeScroll(name: "arch") {
                let picks = Self.picks(d)
                LazyVStack(spacing: 22) {
                    ForEach(d.entries) { e in row(e, pick: picks[e.id]).id(e.id) }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if let no = m.focusNo, let e = d.entries.first(where: { $0.no == no }) { proxy.scrollTo(e.id, anchor: .center); return }
                    if let t = m.focusTime, let e = d.entries.first(where: { $0.hm == t }) {
                        if let i = markEntries.firstIndex(where: { $0 == e.id }) { markIdx = i }
                        proxy.scrollTo(e.id, anchor: .top); return
                    }
                    if !m.q.isEmpty, let first = markEntries.first { markIdx = 0; proxy.scrollTo(first, anchor: .center) }
                }
            }
            .onChange(of: markIdx) { i in if i >= 0, i < markEntries.count { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(markEntries[i], anchor: .center) } } }
        }
        .overlay(alignment: .bottomTrailing) { if !m.q.isEmpty, markCount > 0 { hitPill } }
        .id(d.date)   // 翻到另一天＝整页重来（滚回顶、命中定位重跑），不带着上一天的滚动位置
    }
    /// 命中逐处跳转（09-21 寻定挪位）：天页右下角一枚小胶囊，和主页「跳到底」那枚同款（同底同圈同影），
    /// 左右各一枚细箭头、中间「2/5」；顶栏只剩日期和 #
    private var hitPill: some View {
        HStack(spacing: 0) {
            Button { jump(-1) } label: {
                Image("chev").renderingMode(.template).resizable().frame(width: 14, height: 14).rotationEffect(.degrees(180))
                    .foregroundColor(Theme.jumpArrow).frame(width: 34, height: 38)
            }.buttonStyle(.plain)
            Text("\(markIdx + 1)/\(markCount)").font(Theme.round(12.5)).foregroundColor(Theme.jumpArrow).frame(minWidth: 30)
            Button { jump(1) } label: {
                Image("chev").renderingMode(.template).resizable().frame(width: 14, height: 14)
                    .foregroundColor(Theme.jumpArrow).frame(width: 34, height: 38)
            }.buttonStyle(.plain)
        }
        .background(Theme.jumpBg, in: Capsule())
        .overlay(Capsule().stroke(Theme.jumpRing, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.10), radius: 9, y: 6)
        .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
        .padding(.trailing, 16).padding(.bottom, 14)
    }
    /// 命中的条（按出现顺序；同一条多处算多次，跳转按条）
    private var markEntries: [String] {
        guard let d = m.day, !m.q.isEmpty else { return [] }
        var out: [String] = []
        for e in d.entries {
            let n = Self.count(m.q, in: (e.text ?? "") + "\n" + (e.thinking ?? "") + (e.note ?? ""))
            for _ in 0..<n { out.append(e.id) }
        }
        return out
    }
    private var markCount: Int { markEntries.count }
    private func jump(_ dir: Int) { guard markCount > 0 else { return }; markIdx = (markIdx + dir + markCount) % markCount }
    static func count(_ q: String, in s: String) -> Int {
        guard !q.isEmpty else { return 0 }
        return s.lowercased().components(separatedBy: q.lowercased()).count - 1
    }
    /// 关键词标黄：赤陶橙 18%
    static func highlight(_ a: NSAttributedString, _ q: String) -> NSAttributedString {
        guard !q.isEmpty else { return a }
        let m = NSMutableAttributedString(attributedString: a)
        let s = m.string as NSString
        var r = NSRange(location: 0, length: s.length)
        while true {
            let f = s.range(of: q, options: .caseInsensitive, range: r)
            if f.location == NSNotFound { break }
            m.addAttribute(.backgroundColor, value: Theme.uiDyn(0xC96442, 0xC96442).withAlphaComponent(0.18), range: f)
            let next = f.location + f.length
            r = NSRange(location: next, length: s.length - next)
        }
        return m
    }

    /// 她哪句是点的选项：和前一条克的话末尾那排比（同聊天页）
    private static func picks(_ d: ArchDay) -> [String: String] {
        var out: [String: String] = [:]
        var options: [String] = []
        for e in d.entries where e.note == nil && e.diary != true {
            if e.role == "assistant" { options = Replies.split(e.text ?? "").options }
            else if e.role == "user", !e.isPing, let p = Replies.pick(of: e.text, options: options) { out[e.id] = p }
        }
        return out
    }
    @ViewBuilder private func row(_ e: ArchEntry, pick: String? = nil) -> some View {
        let tag: String? = m.showNums ? e.no.map { "#\($0)" } : nil
        let flash = (m.flashNo != nil && m.flashNo == e.no) ? "#\(e.no ?? 0)" : nil
        if let n = e.note {   // 档案里的系统说明块（非对话）
            Text(n).font(Theme.round(12.5)).tracking(0.25).lineSpacing(3).multilineTextAlignment(.center).foregroundColor(Theme.muted)
                .padding(EdgeInsets(top: 9, leading: 15, bottom: 9, trailing: 15))
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundColor(Theme.border))
                .frame(maxWidth: UIScreen.main.bounds.width * 0.82)
        } else if e.diary == true {   // 日记附件：独立小卡，不冒充聊天气泡
            VStack(alignment: .leading, spacing: 4) {
                Text("📔 " + (e.author == "xun" ? "寻" : "克") + "的日记 · " + e.hm).font(Theme.pixel(12)).foregroundColor(Theme.muted)   // 09-15 寻定：像素字
                Text(e.text ?? "").font(Theme.serif(14)).lineSpacing(5).foregroundColor(Theme.text)
            }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.86)
        } else if e.role == "user" && e.isPing {
            PingChipView(msg: pingMsg(e))
        } else if e.role == "user" {
            UserRowView(text: e.voice != nil ? (e.voice?.text ?? Voice.stripNote(Msg.stripWatch(e.text ?? ""))) : Msg.stripWatch(e.text ?? ""), stamp: TimeFmt.stamp(e.ts), images: e.images ?? [], tagNo: tag ?? flash, flash: flash != nil, highlight: m.q, pick: pick, voice: e.voice)
        } else {
            AIRowView(msg: aiMsg(e), showUsage: false, tagNo: tag ?? flash, flash: flash != nil, highlight: m.q, parseReplies: false)   // 档案馆放原文，[reply: …] 照排
        }
    }
    private func pingMsg(_ e: ArchEntry) -> Msg {
        var msg = Msg(role: "user", content: e.text, ts: e.ts, images: e.images)
        msg.meal = e.meal; msg.sleepNote = e.sleepNote; msg.napNote = e.napNote; msg.rainNote = e.rainNote; msg.placeNote = e.placeNote
        return msg
    }
    private func aiMsg(_ e: ArchEntry) -> Msg {
        var msg = Msg(role: "assistant", content: e.text, ts: e.ts, images: e.images)
        msg.thinking = e.thinking; msg.thinkSecs = e.thinkSecs
        return msg
    }

    // MARK: 检索结果
    private var hitsView: some View {
        OrangeScroll(name: "archhits") {
            VStack(alignment: .leading, spacing: 0) {
                if m.hits.isEmpty {
                    Text("没搜到。检索按字面匹配，换个说法试试？").font(Theme.serif(15)).foregroundColor(Theme.muted).padding(.vertical, 12)
                }
                ForEach(m.hits) { h in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 0) {
                            // 09-15 寻定：命中行整行走方舟像素 12
                            Text("\(h.date) \(h.time) · \(h.who ?? "")").font(Theme.pixel(12)).foregroundColor(Theme.accent)
                            if let more = h.dayMore, more > 0 { Text("　这天另有 \(more) 处").font(Theme.pixel(12)).foregroundColor(Theme.muted) }
                        }
                        RichText(attr: Self.highlight(MD.keNS("…" + (h.snippet ?? "") + "…", size: 14.5, weight: .regular, lineHeight: 1.5), m.q))
                    }
                    .padding(.vertical, 12).padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await m.openDay(h.date, time: h.time) } }
                }
                if m.truncated, !m.nextBefore.isEmpty {
                    Button { Task { await m.search("", more: true) } } label: {
                        Text("还有更早的 · 从 \(m.nextBefore) 继续往前翻").font(Theme.round(13)).tracking(0.4).foregroundColor(Theme.muted)
                            .frame(maxWidth: .infinity).padding(11)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    }.buttonStyle(.plain).padding(.top, 14).padding(.bottom, 6)
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 24)
        }
    }
}
