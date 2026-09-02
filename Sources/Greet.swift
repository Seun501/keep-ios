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
                ClawdWeb(state: "idle", flip: false, onReady: { textOn = true })
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
            if !(Preview.on && Preview.screen == "greet") { DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { bye() } }
            Task { await Greet.refreshCache() }
        }
    }
    private func bye() { shown = false }   // 寻定：不淡出，直接走
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
