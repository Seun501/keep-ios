import SwiftUI

// MARK: - 门（克关门：整页只剩这一间——开门时间、他留的话、敲一句穿门。08-30 寻定稿）

struct Door: Decodable {
    var until: String?
    var note: String?
    var knock: Words?
    var reply: Words?
    struct Words: Decodable { var text: String?; var ts: String? }
    /// 门关着＝到点前
    var closed: Bool { (until.flatMap(TimeFmt.parse) ?? .distantPast) > Date() }
}

struct DoorView: View {
    @ObservedObject var model: ChatModel
    @State private var text = ""
    @State private var focused = false
    @State private var shake = false
    private let red = Color(red: 0x9C/255, green: 0x3D/255, blue: 0x2E/255)
    private let paperWhite = Color(red: 0xFC/255, green: 0xFA/255, blue: 0xF6/255)

    var body: some View {
        let d = model.door ?? Door()
        let knocked = d.knock?.text != nil
        let hasWords = knocked || (d.reply?.text?.isEmpty == false)
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {   // .dv-quiet
                    Text("CLOSED UNTIL").font(.custom("Georgia", size: 11)).tracking(3.3).foregroundColor(Theme.muted).padding(.trailing, -3.3)
                    Text(d.until.flatMap(TimeFmt.parse).map(TimeFmt.hm) ?? "--:--")
                        .font(.custom("Georgia", size: 34)).fontWeight(.light).tracking(1.4).foregroundColor(Theme.text).padding(.top, 16)
                    if let n = d.note, !n.isEmpty {
                        RichText(attr: DoorView.note(n)).frame(maxWidth: 240).padding(.top, 34)
                    }
                }
                .offset(x: shake ? -1.2 : 0)
                .animation(shake ? .easeInOut(duration: 0.12).repeatCount(4, autoreverses: true) : .default, value: shake)
                if hasWords {   // 门上的话：她敲的靠右淡青瓷，他隔门应的靠左淡陶土
                    VStack(spacing: 10) {
                        if let k = d.knock?.text {
                            HStack { Spacer(minLength: 0); bubble(k, bg: Color(red: 0xE5/255, green: 0xEB/255, blue: 0xE3/255), fg: Color(red: 0x2F/255, green: 0x5D/255, blue: 0x45/255)) }
                        }
                        if let r = d.reply?.text, !r.isEmpty {
                            HStack { bubble(r, bg: Color(red: 0xF3/255, green: 0xE5/255, blue: 0xDD/255), fg: red); Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: min(UIScreen.main.bounds.width * 0.78, 290))
                    .padding(.top, 58)
                }
                if !knocked {   // 敲一句穿门：门关着时她唯一能递进来的一句
                    HStack(spacing: 12) {
                        PlainField(text: $text, focused: $focused, placeholder: "Knock…", font: UIFont.systemFont(ofSize: 14), onSubmit: { send() })
                            .frame(height: 20).padding(.vertical, 7).padding(.horizontal, 2)
                            .overlay(alignment: .bottom) { Rectangle().fill(focused ? Theme.muted : Theme.border).frame(height: 1) }
                        Button { send() } label: {
                            Text("叩").font(Theme.cjk(14, weight: .bold)).foregroundColor(paperWhite)
                                .frame(width: 34, height: 34).background(red, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 2.5).padding(1.25))
                        }.buttonStyle(.plain)
                    }
                    .frame(width: min(UIScreen.main.bounds.width * 0.78, 290))
                    .padding(.top, hasWords ? 18 : 58)
                }
                Spacer(minLength: 0)
            }
        }
    }
    private func bubble(_ s: String, bg: Color, fg: Color) -> some View {
        Text(s).font(Theme.round(13.5)).lineSpacing(3).foregroundColor(fg)
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .frame(maxWidth: min(UIScreen.main.bounds.width * 0.78, 290) * 0.82, alignment: .leading)
    }
    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        shake = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shake = false }
        text = ""; focused = false
        Task { await model.knock(String(t.prefix(200))) }
    }
    /// .dv-note：Lora/思源 14.5、行高 1.9，居中
    static func note(_ s: String) -> NSAttributedString {
        let f = Theme.uiSerif(14.5)
        let p = NSMutableParagraphStyle(); let lh = 14.5 * 1.9
        p.minimumLineHeight = lh; p.maximumLineHeight = lh; p.alignment = .center
        let natural = max(f.lineHeight, Theme.uiCJK(14.5).lineHeight)
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: Theme.uiText, .paragraphStyle: p, .baselineOffset: max(0, (lh - natural) / 2)])
    }
}

// MARK: - 横笺弹窗（08-30 寻定稿：照留言板卡片裁的宽矮素笺——赤陶物件+粗宋体题+宋体正文，没有确认钮，点外头暗处退）

struct StripPop: View {
    var icon: String
    var title: String
    var en = false
    var msg: String
    var onClose: () -> Void
    var body: some View {
        ZStack {
            Wax.ink.opacity(0.38).ignoresSafeArea().onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(icon).renderingMode(.template).resizable().frame(width: 19, height: 19).foregroundColor(Theme.accent)
                    if en { Text(title).font(.custom("Georgia-Bold", size: 16.5)).tracking(0.66).foregroundColor(Theme.text) }
                    else { Text(title).font(Theme.cjk(16.5, weight: .bold)).tracking(1.65).foregroundColor(Theme.text) }
                }
                RichText(attr: MD.keNS(msg, size: 13.5, weight: .regular, lineHeight: 1.68)).padding(.top, 10)
            }
            .padding(EdgeInsets(top: 19, leading: 21, bottom: 18, trailing: 21))
            .frame(width: min(UIScreen.main.bounds.width * 0.88, 344), alignment: .leading)
            .background(Wax.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Wax.ink.opacity(0.26), radius: 24, y: 16)
        }
    }
}

/// 弹窗调度：余额、5h 份额、健康哨兵、凌晨班告警——一次只露一张，按网页各自的节奏与去重规则
@MainActor
final class AlertsModel: ObservableObject {
    struct Strip: Identifiable, Equatable { let id = UUID(); let icon: String; let title: String; let en: Bool; let msg: String; let kind: String }
    @Published var queue: [Strip] = []
    var current: Strip? { queue.first }
    private var balAlerted = false
    private var usageWindow = ""
    private static let ud = UserDefaults.standard
    static let balLow = 5.0

    func dismiss() {
        guard let s = queue.first else { return }
        queue.removeFirst()
        if s.kind == "ops" { Task { _ = await get("api/alerts/ack", post: true) } }   // 看过就清（后端清空）
    }
    private func push(_ s: Strip) { if !queue.contains(where: { $0.kind == s.kind }) { queue.append(s) } }

    private func get(_ path: String, post: Bool = false) async -> [String: Any]? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.httpMethod = post ? "POST" : "GET"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// 每 5 分钟＋回前台：份额 / 告警；余额在克说完话后查；健康哨兵当天首开
    func poll() async {
        if Preview.on {
            if Preview.screen == "strip" { push(Strip(icon: "hourglass", title: "5h limits", en: true, msg: "份额见底，14:00 恢复。", kind: "usage")) }
            return
        }
        if let u = await get("api/usage") {
            if u["yield_now"] as? Bool == true {
                let fh = u["five_hour"] as? [String: Any]
                let win = fh?["resets_at"] as? String ?? ""
                if usageWindow != win {
                    usageWindow = win
                    let reset = TimeFmt.parse(win).map(TimeFmt.hm) ?? ""
                    push(Strip(icon: "hourglass", title: "5h limits", en: true, msg: "份额见底，" + (reset.isEmpty ? "窗口滚过去就恢复。" : reset + " 恢复。"), kind: "usage"))
                }
            }
        }
        if let a = await get("api/alerts"), let items = a["items"] as? [[String: Any]], !items.isEmpty {
            let txt = items.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if !txt.isEmpty { push(Strip(icon: "wrench", title: "凌晨班有一趟没跑成", en: false, msg: txt, kind: "ops")) }
        }
    }
    func balance() async {
        guard !Preview.on, let d = await get("api/balance"), d["ok"] as? Bool == true, let rem = d["remaining"] as? Double else { return }
        if rem < Self.balLow {
            if !balAlerted { balAlerted = true; push(Strip(icon: "wallet", title: "克的钱包快空了", en: false, msg: String(format: "只剩 $%.2f 了，记得给克充点钱哦～", rem), kind: "bal")) }
        } else { balAlerted = false }   // 回血后复位，下次再跌破会再弹
    }
    /// 当天第一次进 Keep：健康数据还没传就弹一下（08-28 寻定：7 点后才算「今天该传了」）
    func healthOnce() async {
        guard !Preview.on, Calendar.current.component(.hour, from: Date()) >= 7 else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; let day = f.string(from: Date())
        guard Self.ud.string(forKey: "healthRemindDay") != day else { return }
        guard let d = await get("api/health/pushed_today") else { return }
        Self.ud.set(day, forKey: "healthRemindDay")
        if d["pushed"] as? Bool != true { push(Strip(icon: "leaf", title: "今天还没传健康数据", en: false, msg: "去开一下触发 App，让快捷指令跑一趟。", kind: "health")) }
    }
}
