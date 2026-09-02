import SwiftUI

/// 门楣（克写的一行话）＋天气行（实时，不带地名）。照网页 #lintelCol：
/// 门楣 Noto 600 15.5 赤陶；天气 13 同宋体同橙压 .6，线条图标 15。
@MainActor
final class LintelModel: ObservableObject {
    @Published var text = ""
    @Published var wxLabel = ""
    @Published var wxCode = 3
    @Published var wxTemp: Double? = nil
    @Published var wxDay = true

    func refresh() async {
        async let l: [String: Any]? = fetch("api/lintel")
        async let w: [String: Any]? = fetch("api/weather")
        if let l = await l { text = (l["text"] as? String) ?? "" }
        if let w = await w {
            wxLabel = (w["label"] as? String) ?? ""
            wxCode = (w["code"] as? Int) ?? 3
            wxTemp = w["temp"] as? Double
            wxDay = ((w["is_day"] as? Int) ?? 1) == 1
            Greet.cacheWeather(code: wxCode, temp: wxTemp)
        }
    }

    private func fetch(_ path: String) async -> [String: Any]? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 20
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// WMO 码 → 线条图标（照网页 wxKind）
    var symbol: String {
        let c = wxCode
        if c == 0 || c == 1 { return wxDay ? "sun.max" : "moon" }
        if c == 2 { return wxDay ? "cloud.sun" : "cloud.moon" }
        if c == 3 { return "cloud" }
        if c == 45 || c == 48 { return "cloud.fog" }
        if (71...77).contains(c) || c == 85 || c == 86 { return "cloud.snow" }
        if c >= 95 { return "cloud.bolt" }
        if c >= 51 { return "cloud.rain" }
        return "cloud"
    }
    var wxText: String { wxLabel + (wxTemp.map { " \(Int($0.rounded()))°" } ?? "") }
}

struct LintelColumn: View {
    @ObservedObject var m: LintelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !m.text.isEmpty {
                Text(m.text).font(Theme.cjk(15.5, weight: .semibold)).tracking(0.8)
                    .foregroundColor(Theme.accent).lineLimit(1).truncationMode(.tail)
            }
            if !m.wxLabel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: m.symbol).font(.system(size: 13, weight: .regular))
                    Text(m.wxText).font(Theme.cjk(13, weight: .semibold)).tracking(0.65)
                }
                .foregroundColor(Theme.accent.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14).padding(.trailing, 8)
    }
}

/// 吃饭钮的碗（照网页 #mealBtn 的 SVG：半圆碗＋底座＋两缕热气）
struct BowlIcon: View {
    var color: Color = Theme.muted
    var size: CGFloat = 20
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            var p = Path()
            p.addArc(center: CGPoint(x: 12 * s, y: 10.5 * s), radius: 8 * s,
                     startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.closeSubpath()
            var base = Path(); base.move(to: CGPoint(x: 9.5 * s, y: 20.5 * s)); base.addLine(to: CGPoint(x: 14.5 * s, y: 20.5 * s))
            var steam = Path()
            for x in [9.5, 14.5] {
                steam.move(to: CGPoint(x: x * s, y: 6.5 * s))
                steam.addCurve(to: CGPoint(x: x * s, y: 3.5 * s),
                               control1: CGPoint(x: (x - 0.9) * s, y: 5.5 * s), control2: CGPoint(x: (x + 0.9) * s, y: 4.5 * s))
            }
            let style = StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round)
            ctx.stroke(p, with: .color(color), style: style)
            ctx.stroke(base, with: .color(color), style: style)
            ctx.stroke(steam, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
    }
}
