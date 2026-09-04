import SwiftUI
import UIKit

// MARK: - 数据（照 letters.py view_for_xun 的行）

struct Letter: Decodable, Identifiable {
    var id: String
    var author: String
    var ts: String
    var locked: Bool
    var content: String?
    var until: String?
    var hasPassphrase: Bool?
    var seen: Bool?
    var justUnlocked: Bool?
    var myLock: MyLock?
    struct MyLock: Decodable { var until: String?; var sealed: Bool? }
    enum CodingKeys: String, CodingKey {
        case id, author, ts, locked, content, until, seen
        case hasPassphrase = "has_passphrase", justUnlocked = "just_unlocked", myLock = "my_lock"
    }
    var mine: Bool { author == "xun" }
}

struct LettersPayload: Decodable {
    var entries: [Letter]
    var badge: Int?
    var unseen: [Letter]?
}

struct LetterDraft: Codable, Identifiable {
    var id: String
    var ts: String
    var content: String
}

/// 信匣（08-25 起：日记本退役、信箱上岗；锁与送达语义在服务器 letters.py）
@MainActor
final class LettersModel: ObservableObject {
    static let shared = LettersModel()
    @Published var entries: [Letter] = []
    @Published var unseen: [Letter] = []
    @Published var badge = 0
    @Published var loaded = false
    @Published var drafts: [LetterDraft] = Preview.on
        ? [LetterDraft(id: "d1", ts: TimeFmt.nowIso(), content: "写到一半的一封，明天再接着。")]   // 截图用的假草稿（我自己的字）
        : LettersModel.loadDrafts()

    private static let ud = UserDefaults.standard

    func refresh() async {
        if Preview.on {
            if let d = Preview.json("preview_letters"), let p = try? JSONDecoder().decode(LettersPayload.self, from: d) {
                entries = p.entries; unseen = p.unseen ?? []; badge = p.badge ?? 0
            }
            loaded = true; return
        }
        guard let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/letters"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(LettersPayload.self, from: d) else { return }
        entries = p.entries; unseen = p.unseen ?? []; badge = p.badge ?? 0
        loaded = true
    }

    private func post(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// 弹窗关掉/信箱翻过＝这批看过了（不推手机，寻定：信安静躺着等她来）
    func markSeen() async {
        unseen = []; badge = 0
        if Preview.on { return }
        _ = await post("api/letters/seen", [:])
    }

    /// 带口令＝用口令提前打开克锁着的那封；不带＝把自己锁着的那封提前寄到。返回错误文案（nil＝成功）
    func unlock(_ id: String, passphrase: String? = nil) async -> String? {
        if Preview.on { return passphrase == nil || passphrase == "月亮" ? nil : "不是这句——再想想" }
        var body: [String: Any] = ["id": id]
        if let passphrase { body["passphrase"] = passphrase }
        guard let d = await post("api/letters/unlock", body) else { return "没连上" }
        if d["ok"] as? Bool == true { await refresh(); return nil }
        return (d["error"] as? String) ?? "不是这句——再想想"
    }

    /// 寄信：extra＝封缄参数（lock_days / lock_until / no_expiry / sealed / passphrase）
    func send(_ content: String, extra: [String: Any]) async -> String? {
        if Preview.on { return nil }
        var body = extra; body["content"] = content
        guard let d = await post("api/letters", body) else { return "没寄出" }
        if d["ok"] as? Bool == true { await refresh(); return nil }
        return (d["error"] as? String) ?? "没寄出"
    }

    // 拆没拆记在她手机里（08-29）：服务器不管
    func opened(_ id: String) -> Bool { (Self.ud.stringArray(forKey: "letterOpened") ?? []).contains(id) }
    func markOpened(_ id: String) {
        var a = Self.ud.stringArray(forKey: "letterOpened") ?? []
        guard !a.contains(id) else { return }
        a.append(id); Self.ud.set(Array(a.suffix(500)), forKey: "letterOpened")
        objectWillChange.send()
    }

    // 草稿（08-28 寻定：可以攒多张；躺在信件栏顶上；寄出或删光字才消失）
    private static func loadDrafts() -> [LetterDraft] {
        guard let d = ud.data(forKey: "letterDrafts"), let a = try? JSONDecoder().decode([LetterDraft].self, from: d) else { return [] }
        return a
    }
    private func saveDrafts() { Self.ud.set(try? JSONEncoder().encode(drafts), forKey: "letterDrafts") }
    /// 写着写着存一笔；删光＝这张自己消失。返回这张的 id（可能是新建的）
    @discardableResult
    func upsertDraft(_ id: String?, _ text: String) -> String? {
        let i = drafts.firstIndex { $0.id == id }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let i { drafts.remove(at: i); saveDrafts() }
            return nil
        }
        if let i { drafts[i].content = text; drafts[i].ts = TimeFmt.nowIso() ; saveDrafts(); return drafts[i].id }
        let nid = String(Int(Date().timeIntervalSince1970 * 1000))
        drafts.append(LetterDraft(id: nid, ts: TimeFmt.nowIso(), content: text)); saveDrafts()
        return nid
    }
    func dropDraft(_ id: String?) { drafts.removeAll { $0.id == id }; saveDrafts() }
}

// MARK: - 文案格式（照网页 fmtDayEnShort / sealWhenLabel / lockWhenLabel）

enum LetterFmt {
    static let months = ["January","February","March","April","May","June","July","August","September","October","November","December"]
    /// 信封邮戳体：Aug 25；跨年才带年份（08-29 寻定）
    static func dayEnShort(_ iso: String?) -> String {
        guard let d = iso.flatMap(TimeFmt.parse) else { return "" }
        let c = Calendar.current
        let s = months[c.component(.month, from: d) - 1].prefix(3) + " \(c.component(.day, from: d))"
        let y = c.component(.year, from: d)
        return y == c.component(.year, from: Date()) ? String(s) : "\(s), \(y)"
    }
    static func dayEn(_ iso: String?) -> String {
        guard let d = iso.flatMap(TimeFmt.parse) else { return "" }
        let c = Calendar.current
        return "\(months[c.component(.month, from: d) - 1]) \(c.component(.day, from: d)), \(c.component(.year, from: d))"
    }
    static let wd = ["日","一","二","三","四","五","六"]
    /// 「到 9月3日 周三 · 09:00」
    static func sealWhen(_ d: Date) -> String {
        let c = Calendar.current
        return "到 \(c.component(.month, from: d))月\(c.component(.day, from: d))日 周\(wd[c.component(.weekday, from: d) - 1]) · \(TimeFmt.hm(d))"
    }
    /// 「解封于 9月3日 周三 09:00」（跨年带年）
    static func lockWhen(_ iso: String) -> String {
        guard let d = TimeFmt.parse(iso) else { return "" }
        let c = Calendar.current
        let y = c.component(.year, from: d) != c.component(.year, from: Date()) ? "\(c.component(.year, from: d))年" : ""
        return "解封于 \(y)\(c.component(.month, from: d))月\(c.component(.day, from: d))日 周\(wd[c.component(.weekday, from: d) - 1]) \(TimeFmt.hm(d))"
    }
    /// 信封左下角衬线英文：这封几号开（08-29 寻定：同年不标年份）
    static func lockLine(_ e: Letter) -> String {
        if e.locked { return e.until.map { "Opens " + dayEnShort($0) } ?? "Sealed" }
        if let l = e.myLock {
            if l.sealed == true { return "Arrives " + dayEnShort(l.until) }
            return l.until.map { "Opens " + dayEnShort($0) } ?? "Sealed"
        }
        return ""
    }
    static func lockLabel(_ l: Letter.MyLock) -> String {
        if l.sealed == true { return "🔒 暗寄 · 到 \(TimeFmt.stamp(l.until)) 才出现" }
        return "🔒 " + (l.until.map { "到 \(TimeFmt.stamp($0)) 自动打开" } ?? "要口令才打开")
    }
}

// MARK: - 信封（照 .env：素纸+斜盖影+双发丝线+一枚火漆）

enum Wax {
    static let ke = Color(red: 0x9C/255, green: 0x3D/255, blue: 0x2E/255)        // 朱砂
    static let keRead = Color(red: 0xB0/255, green: 0x85/255, blue: 0x78/255)    // 哑陶
    static let xun = Color(red: 0x2F/255, green: 0x5D/255, blue: 0x45/255)       // 墨绿
    static let xunRead = Color(red: 0x85/255, green: 0xA2/255, blue: 0x92/255)   // 灰松绿
    static let paper = Color(red: 0xFC/255, green: 0xFA/255, blue: 0xF6/255)
    static let ink = Color(red: 48/255, green: 45/255, blue: 39/255)
    static func color(mine: Bool, read: Bool) -> Color { mine ? (read ? xunRead : xun) : (read ? keRead : ke) }
}

/// 翻盖（照网页 .env-flap + .env-flapline）：三角影是 V（顶边到底中，不描边）；两条发丝线是 Λ——
/// 从顶中分别斜到翻盖带的左下、右下角（网页两块半宽渐变的 50% 线各过一对对角）。V 和 Λ 交叉＝寻说的「四条对交的线」；
/// 我之前把线描在 V 的边上，吞了 Λ 那两条（寻验 09-04）
struct EnvelopeFlap: View {
    var height: CGFloat = 44
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: height)); p.closeSubpath() }
                .fill(Wax.ink.opacity(0.045))
            Path { p in p.move(to: CGPoint(x: 0, y: height)); p.addLine(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w, y: height)) }
                .stroke(Theme.border.opacity(0.7), lineWidth: 0.4)   // 发丝：网页那根是 1px 渐变虚化的，原生 0.8 显粗、0.5 还显（寻验 09-04 二回、三回）
        }
        .frame(height: height)
    }
}

/// 火漆：实色圆；锁着的顺翻盖走向压两道白细线
struct WaxSeal: View {
    var color: Color
    var locked: Bool
    var size: CGFloat = 17
    var body: some View {
        ZStack {
            Circle().fill(color)
            if locked {
                // 网页 .wax.lockx：两道 1.5 白线走 14deg / 166deg 渐变＝近乎横着的扁 X（顺翻盖走向）；我之前画成竖的（寻 09-05 拿原图纠正）
                // 线 0.6（网页 1.5 是渐变虚化的；寻 09-05：「再细！得细很多」）
                Rectangle().fill(Color.white.opacity(0.72)).frame(width: size, height: 0.6).rotationEffect(.degrees(14))
                Rectangle().fill(Color.white.opacity(0.72)).frame(width: size, height: 0.6).rotationEffect(.degrees(-14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .shadow(color: Wax.ink.opacity(0.2), radius: 1.5, y: 1)
    }
}

/// 信匣里的一封（.env 86 高）：蜡色认人、鲜哑认拆没拆、蜡上压纹认锁；右下邮戳、左下开封日
struct EnvelopeView: View {
    let e: Letter
    let read: Bool
    var body: some View {
        let lockedAny = e.locked || e.myLock != nil
        ZStack(alignment: .topLeading) {
            Wax.paper
            EnvelopeFlap(height: 44)
            WaxSeal(color: Wax.color(mine: e.mine, read: !lockedAny && read), locked: lockedAny)
                .frame(maxWidth: .infinity).offset(y: 36)
            let lk = LetterFmt.lockLine(e)
            if !lk.isEmpty {
                Text(lk).font(.custom("Georgia", size: 11)).tracking(0.66).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 14).padding(.bottom, 9)
            }
            Text(LetterFmt.dayEnShort(e.ts) + " · " + TimeFmt.hm(e.ts)).font(.custom("Georgia", size: 11)).tracking(0.66).foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 12).padding(.bottom, 9)
        }
        .frame(height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.8))   // 寻验 09-04：1 偏粗
        .contentShape(Rectangle())
    }
}

// MARK: - 信匣列表（草稿在顶、信封按月）＋ 写信圆球

struct LettersList: View {
    @ObservedObject var m: LettersModel
    var onOpen: (Letter) -> Void
    var onLocked: (Letter) -> Void
    var onDraft: (LetterDraft) -> Void

    var body: some View {
        let newest = Array(m.entries.reversed())
        let nowMon = monLabel(Date())
        ForEach(m.drafts) { d in DraftCard(d: d, onDelete: { m.dropDraft(d.id) }, onOpen: { onDraft(d) }) }
        ForEach(monthGroups(newest), id: \.0) { mon, arr in
            if mon != nowMon { SecTitle(mon) }
            ForEach(arr) { e in
                EnvelopeView(e: e, read: e.mine || m.opened(e.id))
                    .onTapGesture { if e.locked { onLocked(e) } else { onOpen(e) } }
            }
        }
        if m.loaded && m.entries.isEmpty && m.drafts.isEmpty {
            Text("还没有信。你写的会寄到他手上，他写的会躺在这里。").font(Theme.round(14)).foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity).padding(.top, UIScreen.main.bounds.height * 0.3)
        }
    }
    private func monthGroups(_ arr: [Letter]) -> [(String, [Letter])] {
        var out: [(String, [Letter])] = []
        for e in arr {
            let mon = monLabel(TimeFmt.parse(e.ts) ?? Date())
            if let last = out.last, last.0 == mon { out[out.count - 1].1.append(e) } else { out.append((mon, [e])) }
        }
        return out
    }
    private func monLabel(_ d: Date) -> String {
        let cn = ["一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"]
        let c = Calendar.current
        let y = c.component(.year, from: d), mo = c.component(.month, from: d)
        return (y != c.component(.year, from: Date()) ? "\(y)年 " : "") + cn[mo - 1]
    }
}

/// 草稿卡：虚线框素卡，正文灰一行；往左划露出删除键（08-28 寻定，不打「草稿」二字）
struct DraftCard: View {
    let d: LetterDraft
    var onDelete: () -> Void
    var onOpen: () -> Void
    @State private var dx: CGFloat = 0
    @State private var opened = false
    var body: some View {
        ZStack(alignment: .trailing) {
            // 删除键（照 .draft-del：40 圆、橙）：叉＝右下角那个全角＋原样转 45°（寻验 09-04 二回：和＋一般大，「相当于旋转一下」）
            Text("＋").font(.system(size: 25, weight: .light)).foregroundColor(.white).rotationEffect(.degrees(45))
                .frame(width: 40, height: 40).background(Circle().fill(Theme.accent).shadow(color: Theme.accent.opacity(0.32), radius: 7, y: 5))
                .padding(.trailing, 6)
                .contentShape(Circle())
                .onTapGesture { onDelete() }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LetterFmt.dayEn(d.ts)).font(.custom("Georgia-Bold", size: 16)).tracking(0.16).foregroundColor(Theme.text)
                    Spacer()
                    Text(TimeFmt.hm(d.ts)).font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
                }
                Text(d.content.replacingOccurrences(of: "\n", with: " ")).font(Theme.serif(14.5)).foregroundColor(Theme.muted).lineLimit(1)
            }
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 86)   // 同信封一样高（寻验 09-04）
            .background(Theme.boardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundColor(Theme.border))
            .contentShape(Rectangle())
            .onTapGesture { if opened { opened = false; withAnimation(.easeOut(duration: 0.25)) { dx = 0 } } else { onOpen() } }
            // 横划优先于外面的竖滚（不然滚动区先把手势拿走，卡划不开）
            .highPriorityGesture(DragGesture(minimumDistance: 10).onChanged { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                dx = min(0, max(-56, (opened ? -56 : 0) + v.translation.width))
            }.onEnded { _ in
                opened = dx < -28
                withAnimation(.easeOut(duration: 0.25)) { dx = opened ? -56 : 0 }
            })
            // 点击区和手势都放在 offset 里头，跟着卡一起挪。原来挂在 offset 外头：卡划开了、点击区还留在原位盖着 ✕，
            // 点叉＝卡缩回、删不掉（寻验 09-04 两回「还是无法删除草稿」的病根）
            .offset(x: dx)
        }
    }
}

// MARK: - 读信（08-27 寻定：新页全屏、主聊天底色、无头排、正文大字、时间落款在最尾）

struct LetterReadView: View {
    let e: Letter
    @ObservedObject var m: LettersModel
    var onBack: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RichText(attr: LetterReadView.bodyText(e.content ?? ""))
                HStack {
                    Spacer()
                    Text(TimeFmt.stamp(e.ts) + (e.myLock.map { " · " + LetterFmt.lockLabel($0) } ?? ""))
                        .font(Theme.round(11.5)).tracking(0.46).foregroundColor(Theme.muted)
                }.padding(.top, 18)
                if e.myLock != nil {
                    HStack {
                        Spacer()
                        Button { Task { _ = await m.unlock(e.id); onBack() } } label: {
                            Text("现在就寄到").font(Theme.round(12)).foregroundColor(Theme.muted)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }.padding(.top, 13)
                }
            }
            .padding(EdgeInsets(top: 6, leading: 4, bottom: 30, trailing: 4))
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
        .scrollIndicators(.visible)
        .background(Theme.bg.ignoresSafeArea())
        .background(EdgeSwipe(onBack: onBack))
        .onAppear { m.markOpened(e.id) }   // 摊开即算拆过——回列表蜡就转哑色
    }
    /// 正文照 .letter-read .pf-body：16.5/1.8、500 档（粗细对齐克主聊天正文，08-28 寻定）；原样文字，不解 markdown
    static func bodyText(_ s: String) -> NSAttributedString {
        let f = Theme.uiSerif(16.5, weight: .medium)
        let p = NSMutableParagraphStyle()
        let lh = 16.5 * 1.8
        p.minimumLineHeight = lh; p.maximumLineHeight = lh
        let natural = max(f.lineHeight, Theme.uiCJK(16.5, weight: .medium).lineHeight)
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: Theme.uiText, .paragraphStyle: p, .baselineOffset: max(0, (lh - natural) / 2)])
    }
}

// MARK: - 写信（08-28 重裁：素纸全屏，✕/纸飞机钉在顶上，锁的事全收进封缄弹层）

struct LetterComposeView: View {
    @ObservedObject var m: LettersModel
    var draft: LetterDraft?
    var onClose: () -> Void
    var onSent: () -> Void
    @State private var text = ""
    @State private var draftId: String? = nil
    @State private var sealing = false
    @State private var focused = false
    @State private var error: String? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            LetterTextArea(text: $text, focused: $focused)
                .padding(.horizontal, 22 + 4)
                .padding(.top, 54)
                .padding(.bottom, 14)
                .onChange(of: text) { t in draftId = m.upsertDraft(draftId, t) }
            HStack(alignment: .center) {
                // ✕ 同纸飞机一样大、一样高（寻验 09-04：26 太大）
                Button { onClose() } label: { Text("✕").font(.system(size: 19, weight: .light)).foregroundColor(Theme.muted).frame(width: 23, height: 23).padding(8) }.buttonStyle(.plain)
                Spacer()
                Button {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { focused = false; sealing = true }
                } label: {
                    Image("plane").renderingMode(.template).resizable().frame(width: 23, height: 23).foregroundColor(Theme.muted).padding(8)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
        .background(EdgeSwipe(onBack: onClose))
        .overlay {
            if sealing {
                SealSheet(onCancel: { sealing = false }, onSend: { extra in
                    Task {
                        if let err = await m.send(text.trimmingCharacters(in: .whitespacesAndNewlines), extra: extra) { error = err }
                        else { m.dropDraft(draftId); sealing = false; onSent() }
                    }
                }).zIndex(5)
            }
        }
        .alert("没寄出", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
        .onAppear {
            text = draft?.content ?? ""; draftId = draft?.id
            let sealShot = Preview.on && (Preview.screen == "seal" || Preview.screen == "sealdate")
            if !sealShot { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
            if sealShot { sealing = true }
        }
    }
}

/// 写信的纸：UITextView（.letter-ta：16.5/1.8、500 档、无框透明、Writing… 占位；字在框内滚，光标可见交给系统）
struct LetterTextArea: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    static var attrs: [NSAttributedString.Key: Any] {
        let f = Theme.uiSerif(16.5, weight: .medium)
        let p = NSMutableParagraphStyle(); let lh = 16.5 * 1.8
        p.minimumLineHeight = lh; p.maximumLineHeight = lh
        let natural = max(f.lineHeight, Theme.uiCJK(16.5, weight: .medium).lineHeight)
        return [.font: f, .foregroundColor: Theme.uiText, .paragraphStyle: p, .baselineOffset: max(0, (lh - natural) / 2)]
    }
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0); tv.textContainer.lineFragmentPadding = 0
        tv.typingAttributes = Self.attrs
        tv.tintColor = Theme.uiScrollTint.withAlphaComponent(0.85)
        tv.showsVerticalScrollIndicator = false
        tv.keyboardDismissMode = .interactive
        tv.delegate = context.coordinator
        let ph = UILabel(); ph.text = "Writing…"; ph.font = Theme.uiSerif(16.5, weight: .medium)
        ph.textColor = UIColor(red: 0x7E/255, green: 0x7D/255, blue: 0x77/255, alpha: 1)
        ph.sizeToFit(); ph.frame.origin = CGPoint(x: 0, y: 6 + 6)
        tv.addSubview(ph); context.coordinator.placeholder = ph
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text { tv.attributedText = NSAttributedString(string: text, attributes: Self.attrs); tv.typingAttributes = Self.attrs }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        if focused != tv.isFirstResponder { DispatchQueue.main.async { if focused { tv.becomeFirstResponder() } else { tv.resignFirstResponder() } } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LetterTextArea
        weak var placeholder: UILabel?
        init(_ p: LetterTextArea) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            tv.typingAttributes = LetterTextArea.attrs
            placeholder?.isHidden = !tv.text.isEmpty
            if parent.text != tv.text { parent.text = tv.text }
        }
        func textViewDidBeginEditing(_ tv: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ tv: UITextView) { if parent.focused { parent.focused = false } }
    }
}

// MARK: - 封缄弹层（08-28 寻定：纸飞机→弹层挑封多久；从底下滑出、无分割线、无滚动条）

struct SealSheet: View {
    var onCancel: () -> Void
    var onSend: ([String: Any]) -> Void
    enum Mode: Hashable { case days(Double), custom, never }
    @State private var pick: Mode = .days(1)
    @State private var cD = 6                            // 自定义：天/时/分（默认 6 天）
    @State private var cH = 0
    @State private var cM = 0
    // 自定义卡的另一面：直接填 月/日/时（寻验 09-04 二回：小日历难翻，填日子省事——点「到 x月x日」翻面，三只格子换成 月/日/时）
    @State private var byDate = false
    @State private var tMo = 1
    @State private var tDy = 1
    @State private var tHr = 9
    @State private var sealed = false
    @State private var pass = ""
    @State private var passFocused = false
    @State private var up = false
    @State private var alertMsg: String? = nil
    private let presets: [(String, Double)] = [("1 小时", 1.0/24), ("6 小时", 0.25), ("一天", 1), ("一周", 7), ("一个月", 30), ("半年", 182)]

    var body: some View {
        ZStack(alignment: .bottom) {
            Wax.ink.opacity(up ? 0.38 : 0).ignoresSafeArea().onTapGesture { close() }
                .animation(.easeOut(duration: 0.28), value: up)
            VStack(spacing: 0) {
                Capsule().fill(Theme.border).frame(width: 36, height: 4).padding(.top, 6).padding(.bottom, 12)
                HStack(alignment: .firstTextBaseline) {
                    Text("封缄这一封").font(Theme.round(17, weight: .bold)).foregroundColor(Theme.text)
                    Spacer()
                    Button { onSend([:]) } label: { Text("不封").font(Theme.round(14)).foregroundColor(Theme.muted).padding(.vertical, 4).padding(.horizontal, 2) }.buttonStyle(.plain)
                }.padding(.bottom, 2)
                ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                    row(p.0, to: LetterFmt.sealWhen(Date().addingTimeInterval(p.1 * 86400)), mode: .days(p.1))
                }
                // 自定义＝灰卡里三只拨盘，正面 天/时/分、右下角实时报到几时；点那行「到 x月x日」翻到背面，格子换成 月/日/时 直接填，
                // 右下角改报封多久。两面说的是同一个时刻，改哪面另一面都跟着（寻验 09-04：「挑个日子」并进自定义；二回：日历难翻→填日子）
                cus(mode: .custom) {
                    let t = Double(cD) + Double(cH) / 24 + Double(cM) / 1440
                    if byDate {
                        HStack(spacing: 10) {
                            NumCell(value: $tMo, min: 1, max: 12, label: "月")
                            NumCell(value: $tDy, min: 1, max: 31, label: "日")
                            NumCell(value: $tHr, max: 23, label: "时")
                        }
                        Text(t > 0 ? "封 " + spanLabel : "填个日子")
                            .font(Theme.round(12.5)).foregroundColor(Theme.muted).underline(true, pattern: .dot, color: Theme.muted.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 9)
                            .contentShape(Rectangle())
                            .onTapGesture { byDate = false }
                    } else {
                        HStack(spacing: 10) {
                            NumCell(value: $cD, max: 366, label: "天")
                            NumCell(value: $cH, max: 23, label: "时")
                            NumCell(value: $cM, max: 59, label: "分")
                        }
                        Text(t > 0 ? LetterFmt.sealWhen(Date().addingTimeInterval(t * 86400)) : "填个日子")
                            .font(Theme.round(12.5)).foregroundColor(Theme.muted).underline(true, pattern: .dot, color: Theme.muted.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 9)
                            .contentShape(Rectangle())
                            .onTapGesture { flipToDate(t) }
                    }
                }
                row("无时限", to: "拿口令才开", mode: .never)
                HStack(spacing: 13) {
                    Text("暗寄").font(Theme.round(15)).foregroundColor(Theme.text)
                    Spacer()
                    Capsule().fill(sealed ? Theme.accent : Theme.border).frame(width: 46, height: 27)
                        .overlay(alignment: sealed ? .trailing : .leading) { Circle().fill(.white).frame(width: 22, height: 22).padding(2.5) }
                        .animation(.easeOut(duration: 0.18), value: sealed)
                }
                .padding(.vertical, 12).padding(.horizontal, 2).contentShape(Rectangle())
                .onTapGesture { sealed.toggle() }
                HStack(spacing: 13) {
                    Text("口令").font(Theme.round(15)).foregroundColor(Theme.text)
                    Spacer()
                    PlainField(text: $pass, focused: $passFocused, placeholder: "", font: UIFont.systemFont(ofSize: 14))
                        .frame(height: 18)
                        .padding(.vertical, 8).padding(.horizontal, 13)
                        .frame(maxWidth: UIScreen.main.bounds.width * 0.5)
                        .background(Theme.composer, in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairRing, lineWidth: 1))
                }.padding(.vertical, 12).padding(.horizontal, 2)
                let footW = UIScreen.main.bounds.width - 44 - 10   // 取消 : 封起来 = 1 : 1.7（照 .seal-foot flex）
                HStack(spacing: 10) {
                    Button { close() } label: {
                        Text("取消").font(Theme.round(15)).foregroundColor(Theme.text).frame(width: footW / 2.7).frame(minHeight: 47)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }.buttonStyle(.plain)
                    Button { go() } label: {
                        Text("封起来").font(Theme.round(15, weight: .semibold)).tracking(4.5).foregroundColor(Theme.bg).frame(width: footW * 1.7 / 2.7).frame(minHeight: 47)
                            .background(Theme.text, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    }.buttonStyle(.plain)
                }.padding(.top, 14)
            }
            .padding(.horizontal, 22).padding(.bottom, 12)
            .background(Theme.bg, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .offset(y: up ? 0 : UIScreen.main.bounds.height)
            .animation(.timingCurve(0.2, 0.8, 0.25, 1, duration: 0.3), value: up)
            .gesture(DragGesture(minimumDistance: 12).onEnded { v in if v.translation.height > 110 { close() } })
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .onChange(of: tMo * 10000 + tDy * 100 + tHr) { _ in   // 背面填了月/日/时：倒计时拨到那个钟点（今年已过就算明年的）
            guard byDate else { return }
            let cal = Calendar.current
            let y = cal.component(.year, from: Date())
            guard var target = cal.date(from: DateComponents(year: y, month: tMo, day: tDy, hour: tHr)) else { return }
            if target <= Date() { target = cal.date(from: DateComponents(year: y + 1, month: tMo, day: tDy, hour: tHr)) ?? target }
            let s = Swift.max(0, Int((target.timeIntervalSinceNow / 60).rounded()))   // 分钟数
            cD = Swift.min(366, s / 1440); cH = s % 1440 / 60; cM = s % 60
        }
        .alert("还没填好", isPresented: Binding(get: { alertMsg != nil }, set: { if !$0 { alertMsg = nil } })) { Button("好", role: .cancel) {} } message: { Text(alertMsg ?? "") }
        .onAppear {
            DispatchQueue.main.async { up = true }
            if Preview.on, Preview.screen == "seal" { pick = .custom }                       // 截图：自定义正面（天/时/分）
            if Preview.on, Preview.screen == "sealdate" { pick = .custom; flipToDate(6) }    // 截图：自定义背面（月/日/时）
        }
    }

    private func close() { up = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onCancel() } }
    /// 翻到背面：把当前倒计时落到的那个时刻拆成 月/日/时（还没填过就默认明天 09:00）
    private func flipToDate(_ t: Double) {
        let cal = Calendar.current
        var target = Date().addingTimeInterval(t * 86400)
        if t <= 0 { target = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date() }
        tMo = cal.component(.month, from: target); tDy = cal.component(.day, from: target); tHr = cal.component(.hour, from: target)
        byDate = true
    }
    /// 「6 天 3 时」
    private var spanLabel: String {
        var s: [String] = []
        if cD > 0 { s.append("\(cD) 天") }
        if cH > 0 { s.append("\(cH) 时") }
        if cM > 0 { s.append("\(cM) 分") }
        return s.joined(separator: " ")
    }
    private func row(_ lb: String, to: String, mode: Mode) -> some View {
        HStack(spacing: 13) {
            SealDot(on: pick == mode)
            Text(lb).font(Theme.round(15, weight: .semibold)).foregroundColor(Theme.text)
            Spacer()
            Text(to).font(Theme.round(12.5)).foregroundColor(Theme.muted)
        }
        .padding(.vertical, 12).padding(.horizontal, 2).contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.4)) { pick = mode } }   // 选中点和卡一起走（寻验 09-04：点先到、卡后到，「魂在后面追」）
    }
    /// 自定义＝选中鼓成一张灰卡，缓缓展开（08-28 寻定：渐变别太快）
    private func cus<C: View>(mode: Mode, @ViewBuilder belt: () -> C) -> some View {
        let on = pick == mode
        return VStack(spacing: 0) {
            row("自定义", to: "", mode: mode)
            if on { belt().padding(.horizontal, 2).padding(.top, 2) }
        }
        .padding(.horizontal, 10).padding(.bottom, on ? 13 : 0)
        .background(on ? Theme.userBubble : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, -10)
    }
    private func go() {
        var payload: [String: Any] = [:]
        switch pick {
        case .days(let d): payload["lock_days"] = d
        case .custom:
            let t = Double(cD) + Double(cH) / 24 + Double(cM) / 1440
            if t <= 0 { alertMsg = "封多久还没填"; return }
            payload["lock_days"] = t
        case .never:
            if pass.trimmingCharacters(in: .whitespaces).isEmpty { alertMsg = "无时限的锁得配口令，不然这封永远打不开"; return }
            payload["no_expiry"] = true
        }
        if sealed { payload["sealed"] = true }
        let p = pass.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { payload["passphrase"] = p }
        onSend(payload)
    }
}

struct SealDot: View {
    var on: Bool
    var body: some View {
        Circle().stroke(on ? Theme.accent : Theme.border, lineWidth: 1.5).frame(width: 20, height: 20)
            .overlay { if on { Circle().fill(Theme.accent).frame(width: 11, height: 11) } }
    }
}

/// 单格拨盘（08-28 寻定：不露上下的数字，一只白格，上下拨换数、点进去直接打字）
struct NumCell: View {
    @Binding var value: Int
    var min: Int = 0
    var max: Int
    var label: String
    @State private var typing = false
    @State private var buf = ""
    @State private var typingFocus = false
    @State private var acc: CGFloat = 0
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card).shadow(color: Wax.ink.opacity(0.05), radius: 1.5, y: 1)
                if typing {
                    // 点进去＝空格子、光标居中、数字键盘；什么都没填就退出＝保留原数（寻验 09-04）
                    PlainField(text: $buf, focused: $typingFocus, placeholder: "", font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                               align: .center, returnKey: .done, keyboard: .numberPad, onSubmit: { commit() })
                        .frame(height: 22).padding(.horizontal, 6)
                        .onChange(of: typingFocus) { f in if !f { commit() } }
                } else {
                    Text(String(format: "%02d", value)).font(Theme.round(18, weight: .semibold)).foregroundColor(Theme.text)
                }
            }
            .frame(height: 44)
            .overlay { if typing { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.accent, lineWidth: 1.5) } }
            .contentShape(Rectangle())
            .onTapGesture { buf = ""; typing = true; typingFocus = true }
            .gesture(DragGesture(minimumDistance: 6).onChanged { v in
                let step = Int((v.translation.height - acc) / 18)
                if step != 0 { value = Swift.max(min, Swift.min(max, value - step)); acc += CGFloat(step) * 18 }
            }.onEnded { _ in acc = 0 })
            Text(label).font(Theme.round(11.5)).foregroundColor(Theme.muted)
        }
        .frame(maxWidth: .infinity)
    }
    private func commit() {
        guard typing else { return }
        if let n = Int(buf.trimmingCharacters(in: .whitespaces)) { value = Swift.max(min, Swift.min(max, n)) }   // 没填＝原数不动
        typing = false; typingFocus = false
    }
}

// MARK: - 锁信弹窗（08-30 寻定稿：信封凑近看——倒计时+解封钟点+口令行，「启」＝蜡封同色）

struct LockPop: View {
    let e: Letter
    @ObservedObject var m: LettersModel
    var onClose: () -> Void
    @State private var now = Date()
    @State private var pass = ""
    @State private var passFocused = false
    @State private var err = ""
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Wax.ink.opacity(0.38).ignoresSafeArea().onTapGesture { onClose() }
            VStack(spacing: 0) {
                if let until = e.until, let d = TimeFmt.parse(until) {
                    Text(countdown(d)).font(.custom("Georgia", size: 27)).fontWeight(.light).tracking(1.4).foregroundColor(Theme.text).padding(.bottom, 4)
                    Text(LetterFmt.lockWhen(until)).font(Theme.cjk(12.5)).tracking(0.75).foregroundColor(Theme.muted).lineSpacing(4)
                } else {
                    Text("没配钟点——要口令才打开").font(Theme.cjk(12.5)).tracking(0.75).foregroundColor(Theme.muted)
                }
                if e.hasPassphrase == true {
                    HStack(spacing: 12) {
                        PlainField(text: $pass, focused: $passFocused, placeholder: "口令", font: UIFont.systemFont(ofSize: 13), onSubmit: { go() })   // 「口令」靠左（寻 09-05：居左好看）
                            .frame(height: 18).padding(.vertical, 5).padding(.horizontal, 2)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        Button { go() } label: {
                            Text("启").font(Theme.round(12)).tracking(1.8).foregroundColor(Wax.paper)
                                .padding(.horizontal, 13).padding(.vertical, 4)
                                .background(e.mine ? Wax.xun : Wax.ke, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: 190).padding(.top, 14).padding(.bottom, 2)
                    Text(err).font(Theme.round(12)).foregroundColor(Theme.accent).padding(.top, 6).frame(minHeight: 14 + 6)
                }
            }
            .frame(maxWidth: .infinity)
            // 比网页的 64/22/20 收紧一圈（寻 09-05：卡再扁一点、精致一点）
            .padding(EdgeInsets(top: 62, leading: 22, bottom: 14, trailing: 22))
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    Wax.paper
                    EnvelopeFlap(height: 46)
                    WaxSeal(color: e.mine ? Wax.xun : Wax.ke, locked: true, size: 22).offset(y: 46 - 11)
                }
            }
            .frame(width: min(UIScreen.main.bounds.width * 0.82, 310))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 0.8))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Wax.paper).shadow(color: Wax.ink.opacity(0.28), radius: 24, y: 16))   // 投影挂纸上，别给口令框描晕
        }
        .onReceive(tick) { t in
            now = t
            if let until = e.until, let d = TimeFmt.parse(until), d <= t { Task { await m.refresh(); onClose() } }   // 倒到零：信自己开了
        }
    }
    private func countdown(_ d: Date) -> String {
        let s = Swift.max(0, Int(d.timeIntervalSince(now)))
        let dd = s / 86400
        return (dd > 0 ? "\(dd)天 " : "") + String(format: "%02d:%02d:%02d", s % 86400 / 3600, s % 3600 / 60, s % 60)
    }
    private func go() {
        let p = pass.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        Task { if let e2 = await m.unlock(e.id, passphrase: p) { err = e2 } else { onClose() } }
    }
}

// MARK: - 来信到站（08-30 寻定稿：弹窗就是一封信——点信封＝拆，翻盖掀起、蜡退场、信纸升上来再进读信页；点外头暗处＝先收着）

struct LetterAlert: View {
    @ObservedObject var m: LettersModel
    var onOpen: (Letter) -> Void
    var onLocked: (Letter) -> Void
    @State private var opening: String? = nil
    var body: some View {
        ZStack {
            Wax.ink.opacity(0.38).ignoresSafeArea().onTapGesture { Task { await m.markSeen() } }
            VStack(spacing: 14) {
                ForEach(m.unseen) { e in
                    let open = opening == e.id
                    ZStack(alignment: .top) {
                        Wax.paper
                        EnvelopeFlap(height: 46).offset(y: open ? -46 : 0)
                        WaxSeal(color: e.mine ? Wax.xun : Wax.ke, locked: e.locked).offset(y: 38 - 8.5).opacity(open ? 0 : 1).scaleEffect(open ? 0.55 : 1)
                        if e.locked {
                            Text(LetterFmt.lockLine(e)).font(.custom("Georgia", size: 11)).tracking(0.66).foregroundColor(Theme.muted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 14).padding(.bottom, 9)
                        }
                        Text(LetterFmt.dayEnShort(e.ts) + " · " + TimeFmt.hm(e.ts)).font(.custom("Georgia", size: 11)).tracking(0.66).foregroundColor(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 12).padding(.bottom, 9)
                        // 信纸：三道淡线，从底下升上来
                        VStack(alignment: .leading, spacing: 13) {
                            ForEach([0.30, 0.84, 0.64], id: \.self) { w in Rectangle().fill(Color(red: 155/255, green: 145/255, blue: 131/255).opacity(0.32)).frame(width: (min(UIScreen.main.bounds.width * 0.8, 308) - 20 - 32) * w, height: 1) }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0xFF/255, green: 0xFE/255, blue: 0xFB/255), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Wax.ink.opacity(0.10), radius: 7, y: -4)
                        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                        .offset(y: open ? 0 : 102 * 1.15)
                    }
                    .frame(width: min(UIScreen.main.bounds.width * 0.8, 308), height: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    .shadow(color: Wax.ink.opacity(0.28), radius: 24, y: 16)
                    .animation(.easeInOut(duration: 0.5), value: open)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if e.locked { onLocked(e); return }
                        guard opening == nil else { return }
                        opening = e.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { Task { await m.markSeen(); onOpen(e) } }
                    }
                }
            }
        }
    }
}
