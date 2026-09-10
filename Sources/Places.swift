import SwiftUI
import CoreLocation
import UIKit

/// 常去的地方（09-10 寻定）：她在现场「把这里记成…」，坐标存网关状态＋本机；iOS 地理围栏（最多 20 个、
/// 「始终」定位）到/离时系统把 Keep 拉起来，向网关报一声 → 克那边一张纸条「14:02-寻到了学校」。
/// 克看到的永远是名字和她写的描述，不是经纬度。
struct Place: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var desc: String
    var lat: Double
    var lon: Double
    var radius: Int

    static func cached() -> [Place] {
        guard let d = UserDefaults.standard.data(forKey: "places.cache") else { return [] }
        return (try? JSONDecoder().decode([Place].self, from: d)) ?? []
    }
    static func cache(_ ps: [Place]) {
        if let d = try? JSONEncoder().encode(ps) { UserDefaults.standard.set(d, forKey: "places.cache") }
    }
    /// 截图用的假地方（我自己的样张，不是寻的）
    static let fixtures: [Place] = [
        Place(id: "f1", name: "书店", desc: "巷子口那家旧书店，二楼靠窗的位子", lat: 30.0, lon: 104.0, radius: 100),
        Place(id: "f2", name: "公园", desc: "早上跑步绕湖一圈", lat: 30.0, lon: 104.0, radius: 200),
    ]
}

@MainActor
final class PlacesModel: ObservableObject {
    @Published var places: [Place] = Preview.on ? Place.fixtures : Place.cached()
    @Published var now = Preview.on ? "书店" : ""
    @Published var status = ""
    @Published var failed = false

    private func req(_ path: String, method: String = "GET", json: [String: Any]? = nil) -> URLRequest? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path)); r.timeoutInterval = 20
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    func load() async {
        if Preview.on { return }
        guard let r = req("api/places") else { return }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { failed = true; return }
        if (resp as? HTTPURLResponse)?.statusCode == 404 { status = "网关这扇门明早 05:30 重启后才开——今天先记不了"; return }
        struct P: Decodable { var places: [Place]; var now: String? }
        guard let p = try? JSONDecoder().decode(P.self, from: d) else { failed = true; return }
        places = p.places; now = p.now ?? ""
        Place.cache(places)
        Fences.shared.apply(places)
    }

    /// 记下「这里」：拿一次精确定位 → 存网关 → 装围栏
    func add(name: String, desc: String, radius: Int) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if Preview.on { places.append(Place(id: UUID().uuidString, name: n, desc: desc, lat: 0, lon: 0, radius: radius)); return }
        status = "定位中…"
        Fences.shared.requestAlways()
        guard let loc = await Fences.shared.locate(accuracy: kCLLocationAccuracyBest, timeout: 12) else {
            status = "没拿到定位——看看 设置→Keep→位置 是不是关着"; return
        }
        let body: [String: Any] = ["name": n, "desc": desc.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude, "radius": radius]
        guard let r = req("api/places", method: "POST", json: body),
              let (d, resp) = try? await URLSession.shared.data(for: r) else { status = "没送到网关"; return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 { status = "网关这扇门明早 05:30 重启后才开——今天先记不了"; return }
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pd = try? JSONSerialization.data(withJSONObject: j["place"] ?? [:]),
              let p = try? JSONDecoder().decode(Place.self, from: pd) else { status = "网关没收（\(code)）"; return }
        places.removeAll { $0.id == p.id }; places.append(p)
        Place.cache(places); Fences.shared.apply(places)
        status = "记下了：\(p.name)（定位误差约 \(Int(loc.horizontalAccuracy)) 米）"
        PushRegistrar.diag("place: added radius=\(radius) acc=\(Int(loc.horizontalAccuracy))")
    }

    func remove(_ p: Place) async {
        if Preview.on { places.removeAll { $0.id == p.id }; return }
        guard let r = req("api/places/\(p.id)", method: "DELETE"),
              let (_, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { status = "没删掉——再试一次"; return }
        places.removeAll { $0.id == p.id }
        Place.cache(places); Fences.shared.apply(places)
        status = ""
    }
}

/// 围栏总管：每次启动都要建（系统在后台把 App 拉起来交事件，收件人得在）。
@MainActor
final class Fences: NSObject, CLLocationManagerDelegate {
    static let shared = Fences()
    private var mgr: CLLocationManager?
    private var cont: CheckedContinuation<CLLocation?, Never>?
    private var lastWhere: (String, Date)?

    private var manager: CLLocationManager {
        if let m = mgr { return m }
        let m = CLLocationManager(); m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyHundredMeters
        mgr = m
        return m
    }

    var authorization: CLAuthorizationStatus { Preview.on ? .authorizedAlways : manager.authorizationStatus }
    var authLabel: String {
        switch authorization {
        case .authorizedAlways: return "始终"
        case .authorizedWhenInUse: return "使用期间"
        case .denied, .restricted: return "关着"
        default: return "还没问"
        }
    }

    /// 启动：把上次拉到的地方装成围栏（联网拉到新的再换）
    func start() {
        guard !Preview.on else { return }
        apply(Place.cached())
    }

    func requestAlways() {
        guard !Preview.on else { return }
        manager.requestAlwaysAuthorization()   // 已是「使用期间」→ 系统当场弹「改成始终」；没问过→ 先弹使用期间、日后自己再弹一次
    }

    func apply(_ places: [Place]) {
        guard !Preview.on, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let want = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        for r in manager.monitoredRegions where want[r.identifier] == nil { manager.stopMonitoring(for: r) }
        for p in places {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                                          radius: CLLocationDistance(p.radius), identifier: p.id)
            region.notifyOnEntry = true; region.notifyOnExit = true
            manager.startMonitoring(for: region)   // 同名重装＝换掉旧圆
        }
    }

    /// 一次定位（页面记地方用 best；快照带地名用 hundredMeters）
    func locate(accuracy: CLLocationAccuracy, timeout: TimeInterval) async -> CLLocation? {
        guard !Preview.on else { return nil }
        let m = manager
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
        guard m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways else { return nil }
        cont?.resume(returning: nil); cont = nil
        m.desiredAccuracy = accuracy
        return await withCheckedContinuation { c in
            cont = c; m.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.cont?.resume(returning: nil); self?.cont = nil }
        }
    }

    /// 此刻大概在哪（本机反查成地名，十分钟内复用）：「青羊区·人民中路一带」。不在记过的地方时给克看的就是它。
    func whereText() async -> String? {
        guard !Preview.on else { return nil }
        if let (s, at) = lastWhere, Date().timeIntervalSince(at) < 600 { return s }
        guard let loc = await locate(accuracy: kCLLocationAccuracyHundredMeters, timeout: 5) else { return nil }
        guard let pm = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "zh-CN")).first else { return nil }
        let area = pm.subLocality ?? pm.locality ?? pm.administrativeArea ?? ""
        let road = pm.thoroughfare ?? pm.name ?? ""
        let s = [area, road].filter { !$0.isEmpty }.joined(separator: "·")
        guard !s.isEmpty else { return nil }
        let text = s + "一带"
        lastWhere = (text, Date())
        return text
    }

    // MARK: 事件 → 网关

    private func report(_ id: String, _ kind: String) {
        guard let token = Keychain.token else { return }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "place")   // 后台被拉起只有几秒，先讨一段
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/places/event")); r.timeoutInterval = 20
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "kind": kind])
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            Task { @MainActor in
                PushRegistrar.diag("place: \(kind) code=\(code)")
                UIApplication.shared.endBackgroundTask(bg)
            }
        }.resume()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in self.report(region.identifier, "enter") }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in self.report(region.identifier, "exit") }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.cont?.resume(returning: locations.last); self.cont = nil }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.cont?.resume(returning: nil); self.cont = nil }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let note = "place: monitor failed \(region?.identifier ?? "?"): \(error.localizedDescription)"
        Task { @MainActor in PushRegistrar.diag(note) }
    }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let raw = manager.authorizationStatus.rawValue
        Task { @MainActor in PushRegistrar.diag("place: auth=\(raw)") }
    }
}

/// 页面：顶上「把这里记成…」的小表单，下面记过的地方；长按一张卡＝删除。
struct PlacesScreen: View {
    var onBack: () -> Void
    @StateObject private var m = PlacesModel()
    @State private var name = ""
    @State private var desc = ""
    @State private var nameF = false
    @State private var descF = false
    @State private var radius = 100
    @State private var saving = false
    private static let fieldFont: UIFont = {
        let d = UIFont.systemFont(ofSize: 14).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: 14).fontDescriptor
        return UIFont(descriptor: d, size: 14)
    }()

    var body: some View {
        ZStack {
            Theme.boardBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { onBack() } label: { Text("‹").font(.system(size: 26)).foregroundColor(Theme.muted).frame(width: 34, height: 34) }.buttonStyle(.plain).padding(.leading, -8)
                    Text("常去的地方").font(Theme.round(14)).foregroundColor(Theme.muted)
                    Spacer()
                    if !m.now.isEmpty { Text("此刻在：" + m.now).font(Theme.round(12)).foregroundColor(Theme.accent) }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                OrangeScroll(name: "places") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        SecTitle("把这里记成…")
                        form
                        if !m.status.isEmpty {
                            Text(m.status).font(Theme.round(11)).tracking(0.44).lineSpacing(4).foregroundColor(Theme.muted).padding(.horizontal, 2).padding(.top, -2)
                        }
                        SecTitle("记过的地方 · \(m.places.count)")
                        if m.failed { Text("没拿到数据，退出来再进一次试试").font(Theme.round(14)).foregroundColor(Theme.muted).frame(maxWidth: .infinity).padding(.top, 24) }
                        ForEach(m.places) { p in card(p) }
                        if m.places.isEmpty, !m.failed {
                            Text("还一个都没记。到了常去的地方，回来这页按一下就好。").font(Theme.round(12)).lineSpacing(4).foregroundColor(Theme.muted).padding(.horizontal, 2)
                        }
                        if Fences.shared.authorization != .authorizedAlways {
                            Text("定位权限现在是「\(Fences.shared.authLabel)」——要离开手机也能报到，得在 设置→Keep→位置 里选「始终」。")
                                .font(Theme.round(11)).tracking(0.44).lineSpacing(4).foregroundColor(Theme.muted).padding(.horizontal, 2).padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
                }
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .task { await m.load() }
    }

    private var hair: some View { Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1) }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlainField(text: $name, focused: $nameF, placeholder: "叫什么（家 / 学校 / 青羊宫…）", font: Self.fieldFont, returnKey: .next, onSubmit: { descF = true })
                .frame(height: 20).padding(.vertical, 11).padding(.horizontal, 15)
            hair
            PlainField(text: $desc, focused: $descF, placeholder: "给克的一句描述（那是个什么样的地方）", font: Self.fieldFont, returnKey: .done, onSubmit: { descF = false })
                .frame(height: 20).padding(.vertical, 11).padding(.horizontal, 15)
            hair
            HStack(spacing: 8) {
                Text("半径").font(Theme.round(12)).foregroundColor(Theme.muted)
                ForEach([100, 150, 200, 300], id: \.self) { r in
                    Button { radius = r } label: {
                        Text("\(r) 米").font(Theme.round(12, weight: radius == r ? .medium : .regular))
                            .foregroundColor(radius == r ? .white : Theme.muted)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(radius == r ? Theme.accent : Theme.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            HStack {
                Spacer()
                Button {
                    guard !saving else { return }
                    saving = true; nameF = false; descF = false
                    Task { await m.add(name: name, desc: desc, radius: radius); if m.status.hasPrefix("记下了") { name = ""; desc = "" }; saving = false }
                } label: {
                    Text(saving ? "定位中…" : "记下这里").font(Theme.round(14, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 34)
                        .background(Theme.accent.opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1), in: Capsule())
                }.buttonStyle(.plain).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }

    private func card(_ p: Place) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.name).font(Theme.georgiaCJK(16)).foregroundColor(Theme.text)
                Spacer()
                Text("\(p.radius) 米").font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
            }
            if !p.desc.isEmpty {
                Text(p.desc).font(Theme.cjk(13.5)).lineSpacing(4).foregroundColor(Theme.muted).padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
        .contentShape(Rectangle())
        .contextMenu { Button(role: .destructive) { Task { await m.remove(p) } } label: { Label("删除「\(p.name)」", systemImage: "trash") } }
    }
}
