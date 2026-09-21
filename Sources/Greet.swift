import SwiftUI

/// 开屏欢迎语（照网页 showGreet/greetPick）：句池与天气、身体旗用上次缓存，秒出；2.6 秒淡走，点一下也走。
enum Greet {
    static let fallback: [String: [String]] = [
        "早晨": ["早。", "早安。", "新的一天。"], "白天": ["下午好。", "回来啦。"],
        "傍晚": ["晚上好。", "今天辛苦了。"], "夜里": ["夜里好。", "夜深了。"],
        "雨": ["成都在下雨。", "下雨了。"], "雪": ["下雪了！"], "雷": ["打雷了。"],
        "热": ["今天很热，多喝水。"], "冷": ["很冷，穿厚点。"],
        "01-01": ["新年好。"], "02-14": ["情人节快乐。"], "06-01": ["六一快乐。"],
        "10-01": ["国庆快乐。"], "12-24": ["平安夜。"], "12-25": ["圣诞快乐。"], "12-31": ["一年的最后一天了。"],
        "2026-02-16": ["除夕。今晚有年味。"], "2026-02-17": ["新春快乐。"],
        "2026-03-03": ["元宵。汤圆吃了吗？"], "2026-06-19": ["端午安康。"],
    ]
    private static let ud = UserDefaults.standard

    static func cacheWeather(code: Int, temp: Double?) {
        ud.set(["code": code, "temp": temp ?? -999, "ts": Date().timeIntervalSince1970], forKey: "greetWx")
    }
    static func cachePools(_ pools: [String: [String]], health: [String]) {
        ud.set(pools, forKey: "greetPools")
        ud.set(["flags": health, "ts": Date().timeIntervalSince1970], forKey: "greetHealth")
    }

    static func refreshCache() async {
        guard let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/greet"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let (d, _) = try? await URLSession.shared.data(for: r),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let pools = (j["pools"] as? [String: [String]]) ?? [:]
            cachePools(pools, health: (j["health"] as? [String]) ?? [])
        }
    }

    static func pick() -> String {
        let pools = (ud.dictionary(forKey: "greetPools") as? [String: [String]]) ?? [:]
        var wx: (code: Int, temp: Double?)? = nil
        if let w = ud.dictionary(forKey: "greetWx"), let ts = w["ts"] as? Double, Date().timeIntervalSince1970 - ts < 1800 {
            let t = w["temp"] as? Double
            wx = ((w["code"] as? Int) ?? 3, (t ?? -999) <= -900 ? nil : t)
        }
        var hl: [String] = []
        if let h = ud.dictionary(forKey: "greetHealth"), let ts = h["ts"] as? Double, Date().timeIntervalSince1970 - ts < 43200 {
            hl = (h["flags"] as? [String]) ?? []
        }
        func P(_ k: String) -> [String]? {
            if let a = pools[k], !a.isEmpty { return a }
            if let a = fallback[k], !a.isEmpty { return a }
            return nil
        }
        let now = Date()
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "MM-dd"; let mmdd = f.string(from: now)
        f.dateFormat = "yyyy-MM-dd"; let full = f.string(from: now)
        for t in [pools[full], pools[mmdd], fallback[full], fallback[mmdd]] { if let t, !t.isEmpty { return t.randomElement()! } }
        if !hl.isEmpty, Double.random(in: 0..<1) < 0.5, let k = hl.randomElement(), let p = P(k) { return p.randomElement()! }
        if let wx {
            let c = wx.code, tp = wx.temp
            var k: String? = nil, prob = 0.7
            if c >= 95 { k = "雷" }
            else if (71...77).contains(c) || c == 85 || c == 86 { k = "雪" }
            else if c >= 51 { k = (tp != nil && tp! <= 10 && P("雨+冷") != nil) ? "雨+冷" : ([65, 67, 82].contains(c) && P("大雨") != nil) ? "大雨" : "雨" }
            else if let tp, tp >= 35 { k = P("暴热") != nil ? "暴热" : "热" }
            else if let tp, tp <= 2 { k = "冷" }
            else if c == 0 || c == 1 { k = "晴"; prob = 0.25 }
            else if c == 3 { k = "阴"; prob = 0.25 }
            if let k, let p = P(k), Double.random(in: 0..<1) < prob { return p.randomElement()! }
        }
        let wd = cal.component(.weekday, from: now)   // 1=周日
        let wk: String? = (wd == 1 || wd == 7) ? "周末" : wd == 2 ? "周一" : wd == 6 ? "周五" : nil
        if let wk, let p = P(wk), Double.random(in: 0..<1) < 0.4 { return p.randomElement()! }
        let h = cal.component(.hour, from: now)
        let fine = h >= 7 && h < 9 ? "早安" : h >= 9 && h < 11 ? "上午" : h >= 11 && h < 13 ? "午间"
            : h >= 13 && h < 17 ? "下午" : h >= 17 && h < 19 ? "傍晚" : h >= 19 && h < 22 ? "晚上"
            : h >= 22 ? "夜猫子" : h < 3 ? "熬夜" : "通宵"
        let coarse = h >= 5 && h < 11 ? "早晨" : h >= 11 && h < 17 ? "白天" : h >= 17 && h < 22 ? "傍晚" : "夜里"
        return (P(fine) ?? P(coarse))?.randomElement() ?? ""
    }
}

/// 开屏底板：整块纸色盖住正文装配，Clawd 站在屏高 45%、句子在 51%（照 Claude App 构图）。
/// 站位一律按「屏幕坐标」算再减去自己的全局 y——和聊天页 `ClawdModel.layout` 同一把尺（寻验 28：两处差一截＝两把尺）。
/// 句子等 Clawd 的画装好才一起露（寻验 28：字比蟹先出）。
struct GreetOverlay: View {
    @Binding var shown: Bool
    @State private var line = ""
    @State private var textOn = false
    var body: some View {
        GeometryReader { g in
            let H = UIScreen.main.bounds.height
            let top = g.frame(in: .global).minY
            ZStack(alignment: .top) {
                Theme.bg.ignoresSafeArea()
                // 09-21 寻「开屏大半是白纸」：WKWebView 冷启动起进程两三秒，句子等它一起出。开屏这只改原生画（ClawdPixel，
                // 照 clawd-mini-idle.svg 的方块坐标一比一，呼吸/眨眼保留），秒出；聊天页里的蟹照旧走网页
                ClawdPixel()
                    .frame(width: 150, height: 150)
                    .position(x: g.size.width / 2, y: ClawdModel.splashBoxTop(H) + 75 - top)   // 与聊天页开场站位同一个点
                HangingText(text: line)
                    .font(Theme.serif(19, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity)
                    .offset(y: H * 0.51 - top)
                    .opacity(textOn ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { bye() }
        .onAppear {
            line = Greet.pick()
            // 蟹是原生画的、句子池在本地缓存（Greet.pick），两样都是当场有——进门那一帧就露，3.4 秒的表从此刻起走
            // （之前等 WKWebView 的 SVG 装好才露，冷启动两三秒白纸——寻 09-13/09-21）
            reveal()
            Task { await Greet.refreshCache() }
        }
    }
    /// 句子露出，同时起 3.4 秒的表（网页是 2.6s 后起 0.8s 淡出＝实际能看 3.4s；这边瞬切（寻定不淡出），2.6 显得跳得快（寻 09-08））
    private func reveal() {
        guard !textOn else { return }
        textOn = true
        if !(Preview.on && Preview.screen == "greet") { DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { bye() } }
    }
    private func bye() { shown = false }   // 寻定：不淡出，直接走
}

/// 开屏用的原生小 Clawd：照 clawd-mini-idle.svg 一比一（viewBox -15 -25 45 45，150 点见方＝每格 3.33 点）——
/// 四条腿、躯干、两只手、两只眼，#DE886D 与黑；呼吸（3.2 秒 1.02/0.98）和眨眼（每 4 秒眯 0.2 秒）也照 SVG 的节奏。
struct ClawdPixel: View {
    @State private var breathe = false
    @State private var blink = false
    private let body_ = Color(red: 0xDE / 255, green: 0x88 / 255, blue: 0x6D / 255)
    var body: some View {
        GeometryReader { g in
            let s = g.size.width / 45   // 一格
            func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: Color) -> some View {
                c.frame(width: w * s, height: h * s).position(x: (x + 15 + w / 2) * s, y: (y + 25 + h / 2) * s)
            }
            ZStack {
                // 腿（不呼吸）
                R(3, 11, 1, 4, body_); R(5, 11, 1, 4, body_); R(9, 11, 1, 4, body_); R(11, 11, 1, 4, body_)
                // 上身：躯干＋两手＋眼，一起呼吸（transform-origin 7.5,13）
                ZStack {
                    R(2, 6, 11, 7, body_)
                    R(0, 9, 2, 2, body_); R(13, 9, 2, 2, body_)
                    ZStack { R(4, 8, 1, 2, .black); R(10, 8, 1, 2, .black) }
                        .scaleEffect(y: blink ? 0.1 : 1, anchor: UnitPoint(x: 0.5, y: (9 + 25) / 45))
                }
                .scaleEffect(x: breathe ? 1.02 : 1, y: breathe ? 0.98 : 1, anchor: UnitPoint(x: (7.5 + 15) / 45, y: (13 + 25) / 45))
                .offset(y: breathe ? 0.5 * s : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.1)) { blink = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(.easeInOut(duration: 0.1)) { blink = false } }
            }
        }
    }
}

/// 句尾全角标点悬挂（照网页 hanging-punctuation: force-end）：居中按没有它算——整块右移半个标点宽即等效。
struct HangingText: View {
    let text: String
    var body: some View {
        let hang = text.hasSuffix("。") || text.hasSuffix("！") || text.hasSuffix("？") || text.hasSuffix("，")
        Text(text).multilineTextAlignment(.center).lineSpacing(6)
            .offset(x: hang ? 9.5 : 0)
    }
}
