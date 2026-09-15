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
        if Preview.on {   // 截图班：门楣与天气角用假的（09-15 加，看像素字）
            text = "今天风大，围巾戴上。"; wxLabel = "多云"; wxCode = 2; wxTemp = 24; wxDay = true; return
        }
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

/// 门楣两行（09-12 寻定）：天气只占右下角一格，其余地方都是克的字——字绕着天气角排（UITextView 的 exclusionPaths），
/// 两行满了尾部省略。高度固定两行，短句也不塌。服务器给克的上限 28 字，是按 iPhone 11 这个宽算的（一行 17 + 天气旁 11）。
struct LintelColumn: View {
    @ObservedObject var m: LintelModel
    static let lineH = ceil(Theme.uiCJK(15.5, weight: .semibold).lineHeight)
    /// 天气角的尺寸：图标 15 + 间距 5 + 字宽 + 左边留 10
    private var wxBox: CGSize {
        guard !m.wxLabel.isEmpty else { return .zero }
        let w = (m.wxText as NSString).size(withAttributes: [.font: Theme.uiPixel(12)]).width   // 09-15 寻定：像素字 12（整数倍才清楚）
        return CGSize(width: ceil(w) + 15 + 5 + 10, height: Self.lineH)
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LintelText(text: m.text, reserve: wxBox)
            if !m.wxLabel.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: m.symbol).font(.system(size: 13, weight: .regular))
                    Text(m.wxText).font(Theme.pixel(12))
                }
                .foregroundColor(Theme.accent.opacity(0.6))
                .frame(height: Self.lineH)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14).padding(.trailing, 8)
    }
}

struct LintelText: UIViewRepresentable {
    let text: String
    let reserve: CGSize
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false; tv.isSelectable = false; tv.isScrollEnabled = false; tv.isUserInteractionEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 2; tv.textContainer.lineBreakMode = .byTruncatingTail
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = NSAttributedString(string: text, attributes: [
            .font: Theme.uiCJK(15.5, weight: .semibold), .kern: 0.8, .foregroundColor: UIColor(Theme.accent)])
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? (UIScreen.main.bounds.width - 130)
        let h = LintelColumn.lineH * 2
        tv.textContainer.exclusionPaths = reserve.width > 0
            ? [UIBezierPath(rect: CGRect(x: w - reserve.width, y: h - reserve.height, width: reserve.width + 20, height: reserve.height + 20))]
            : []
        return CGSize(width: w, height: h)
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
