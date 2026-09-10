import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// 常去的地方（09-10 寻定）：在地图上长按落钉、起名、选半径；坐标存网关状态＋本机。iOS 地理围栏
/// （最多 20 个、「始终」定位）到/离时系统把 Keep 拉起来，向网关报一声 → 克那边一张纸条「14:02-寻到了学校」。
/// 克看到的是名字和距离，不是经纬度。圆可以套（学校里再钉宿舍/教学楼），服务器报最里面那个。
struct Place: Codable, Identifiable, Equatable {
    var id: String
    var name: String
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
        Place(id: "f1", name: "学校", lat: 30.6600, lon: 104.0900, radius: 300),
        Place(id: "f2", name: "教学楼", lat: 30.6612, lon: 104.0905, radius: 100),
        Place(id: "f3", name: "书店", lat: 30.6720, lon: 104.0760, radius: 100),
    ]
}

/// 国内底图是火星坐标（GCJ-02），手机 GPS 和围栏都是 WGS-84，差几百米：地图上钉的点要换算回 GPS 存，
/// 存着的点画到地图上要换算过去。公开算法，误差几米。境外不换。
enum GeoShift {
    private static let a = 6378245.0, ee = 0.00669342162296594323
    static func outOfChina(_ lat: Double, _ lon: Double) -> Bool { !(lon > 72.004 && lon < 137.8347 && lat > 0.8293 && lat < 55.8271) }
    private static func tLat(_ x: Double, _ y: Double) -> Double {
        var r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        r += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return r
    }
    private static func tLon(_ x: Double, _ y: Double) -> Double {
        var r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        r += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        r += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return r
    }
    static func wgsToGcj(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if outOfChina(c.latitude, c.longitude) { return c }
        var dLat = tLat(c.longitude - 105, c.latitude - 35), dLon = tLon(c.longitude - 105, c.latitude - 35)
        let radLat = c.latitude / 180 * .pi
        var magic = sin(radLat); magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }
    static func gcjToWgs(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        if outOfChina(c.latitude, c.longitude) { return c }
        var w = c
        for _ in 0..<5 {   // 迭代逼近：把 w 正向换算，与目标的差补回去
            let g = wgsToGcj(w)
            w = CLLocationCoordinate2D(latitude: w.latitude - (g.latitude - c.latitude), longitude: w.longitude - (g.longitude - c.longitude))
        }
        return w
    }
}

@MainActor
final class PlacesModel: ObservableObject {
    @Published var places: [Place] = Preview.on ? Place.fixtures : Place.cached()
    @Published var now = Preview.on ? "教学楼" : ""
    @Published var status = ""

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
    private static let notOpen = "网关这扇门明早 05:30 重启后才开——今天先记不了"

    func load() async {
        if Preview.on { return }
        guard let r = req("api/places") else { return }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { status = "没连上网关，先用上次的"; return }
        if (resp as? HTTPURLResponse)?.statusCode == 404 { status = Self.notOpen; return }
        struct P: Decodable { var places: [Place]; var now: String? }
        guard let p = try? JSONDecoder().decode(P.self, from: d) else { status = "网关回的看不懂"; return }
        places = p.places; now = p.now ?? ""
        Place.cache(places)
        Fences.shared.apply(places)
    }

    /// 记下/改一个钉（coord 是 GPS 坐标）。成功返回 true
    func save(id: String?, name: String, coord: CLLocationCoordinate2D, radius: Int) async -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return false }
        if Preview.on {
            let p = Place(id: id ?? UUID().uuidString, name: n, lat: coord.latitude, lon: coord.longitude, radius: radius)
            places.removeAll { $0.id == p.id }; places.append(p); return true
        }
        var body: [String: Any] = ["name": n, "lat": coord.latitude, "lon": coord.longitude, "radius": radius]
        if let id { body["id"] = id }
        guard let r = req("api/places", method: "POST", json: body),
              let (d, resp) = try? await URLSession.shared.data(for: r) else { status = "没送到网关"; return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 { status = Self.notOpen; return false }
        guard code == 200, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pd = try? JSONSerialization.data(withJSONObject: j["place"] ?? [:]),
              let p = try? JSONDecoder().decode(Place.self, from: pd) else { status = "网关没收（\(code)）"; return false }
        places.removeAll { $0.id == p.id }; places.append(p)
        Place.cache(places); Fences.shared.apply(places)
        status = ""
        PushRegistrar.diag("place: saved radius=\(radius) n=\(places.count)")
        return true
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
    private var lastWhere: (String, CLLocation, Date)?

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

    /// 装围栏，并让系统判一次「此刻在不在里面」（didDetermineState）——刚钉的圆站在里面时不会有 didEnter，
    /// 这一问补上；服务器只在状态真变时出纸条，重报无害
    func apply(_ places: [Place]) {
        guard !Preview.on, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let want = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        for r in manager.monitoredRegions where want[r.identifier] == nil { manager.stopMonitoring(for: r) }
        for p in places {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon),
                                          radius: CLLocationDistance(p.radius), identifier: p.id)
            region.notifyOnEntry = true; region.notifyOnExit = true
            manager.startMonitoring(for: region)   // 同名重装＝换掉旧圆
            manager.requestState(for: region)
        }
    }

    /// 一次定位（快照带地名用 hundredMeters）
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

    /// 此刻在哪（十分钟内复用）：GPS 坐标给服务器算「离学校多远」，地名是本机反查的「青羊区·人民中路一带」。
    func whereNow() async -> (String?, CLLocation?) {
        guard !Preview.on else { return (nil, nil) }
        if let (s, l, at) = lastWhere, Date().timeIntervalSince(at) < 600 { return (s, l) }
        guard let loc = await locate(accuracy: kCLLocationAccuracyHundredMeters, timeout: 5) else { return (nil, nil) }
        var text: String? = nil
        if let pm = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "zh-CN")).first {
            let area = pm.subLocality ?? pm.locality ?? pm.administrativeArea ?? ""
            let road = pm.thoroughfare ?? pm.name ?? ""
            let s = [area, road].filter { !$0.isEmpty }.joined(separator: "·")
            if !s.isEmpty { text = s + "一带" }
        }
        if let text { lastWhere = (text, loc, Date()) }
        return (text, loc)
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
        URLSession.shared.dataTask(with: r) { d, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let note = (try? JSONSerialization.jsonObject(with: d ?? Data()) as? [String: Any])?["note"] as? String ?? ""
            Task { @MainActor in
                PushRegistrar.diag("place: \(kind) code=\(code)\(note.isEmpty ? "" : " note")")
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
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard state != .unknown else { return }
        let kind = state == .inside ? "enter" : "exit"
        Task { @MainActor in self.report(region.identifier, kind) }
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

// MARK: - 地图

/// 正在编辑的钉（坐标是 GPS 坐标；id 空＝新钉）
struct PlaceDraft: Equatable {
    var id: String?
    var lat: Double
    var lon: Double
    var radius: Int
}

private final class PlacePin: MKPointAnnotation { var pid: String? }
private final class DraftCircle: MKCircle {}

/// MKMapView 包一层：长按落钉、点钉选中、圆按半径画。地图坐标 ↔ GPS 坐标在这层换算。
struct PlaceMap: UIViewRepresentable {
    var places: [Place]
    var draft: PlaceDraft?
    var centerTick: Int                          // 每加一次＝把地图挪到蓝点
    var searchQuery: String                      // 搜地名跳过去（苹果地图自带搜索）：searchTick 每加一次搜一回
    var searchTick: Int
    var onLongPress: (CLLocationCoordinate2D) -> Void   // GPS 坐标
    var onSelect: (Place) -> Void
    var onSearchNote: (String) -> Void = { _ in }

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = !Preview.on
        mv.pointOfInterestFilter = .excludingAll   // 干净底图（寻的口味）
        mv.showsCompass = false
        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coord.longPress(_:)))
        lp.minimumPressDuration = 0.5
        mv.addGestureRecognizer(lp)
        context.coordinator.map = mv
        // 起始视野：有钉就框住全部；没钉等蓝点来（didUpdate userLocation）；截图/没定位就成都
        if let r = Self.fitRegion(places) { mv.setRegion(r, animated: false) }
        else if Preview.on { mv.setRegion(MKCoordinateRegion(center: GeoShift.wgsToGcj(CLLocationCoordinate2D(latitude: 30.66, longitude: 104.09)), latitudinalMeters: 2500, longitudinalMeters: 2500), animated: false) }
        else { mv.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 30.66, longitude: 104.07), latitudinalMeters: 12000, longitudinalMeters: 12000), animated: false); context.coordinator.wantUserOnce = true }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let co = context.coordinator
        co.parent = self
        let sig = places.map { "\($0.id)|\($0.name)|\($0.lat)|\($0.lon)|\($0.radius)" }.joined(separator: ";") + "#" + (draft.map { "\($0.id ?? "")|\($0.lat)|\($0.lon)|\($0.radius)" } ?? "")
        if sig != co.sig {
            co.sig = sig
            mv.removeAnnotations(mv.annotations.filter { !($0 is MKUserLocation) })
            mv.removeOverlays(mv.overlays)
            for p in places where p.id != draft?.id {
                let c = GeoShift.wgsToGcj(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                let pin = PlacePin(); pin.coordinate = c; pin.title = p.name; pin.pid = p.id
                mv.addAnnotation(pin)
                mv.addOverlay(MKCircle(center: c, radius: CLLocationDistance(p.radius)))
            }
            if let d = draft {
                let c = GeoShift.wgsToGcj(CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon))
                let pin = PlacePin(); pin.coordinate = c; pin.title = d.id.flatMap { id in places.first { $0.id == id }?.name } ?? "这里"
                mv.addAnnotation(pin)
                mv.addOverlay(DraftCircle(center: c, radius: CLLocationDistance(d.radius)))
            }
        }
        if centerTick != co.centerTick {
            co.centerTick = centerTick
            if let l = mv.userLocation.location {
                mv.setRegion(MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 900, longitudinalMeters: 900), animated: true)
            } else { co.wantUserOnce = true }
        }
        if searchTick != co.searchTick {
            co.searchTick = searchTick
            co.search(searchQuery, in: mv)
        }
    }

    static func fitRegion(_ ps: [Place]) -> MKCoordinateRegion? {
        guard !ps.isEmpty else { return nil }
        var rect = MKMapRect.null
        for p in ps {
            let c = GeoShift.wgsToGcj(CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
            let r = MKCircle(center: c, radius: CLLocationDistance(p.radius) * 1.6).boundingMapRect
            rect = rect.union(r)
        }
        var region = MKCoordinateRegion(rect)
        region.span.latitudeDelta = max(region.span.latitudeDelta, 0.006); region.span.longitudeDelta = max(region.span.longitudeDelta, 0.006)
        return region
    }

    final class Coord: NSObject, MKMapViewDelegate {
        var parent: PlaceMap
        weak var map: MKMapView?
        var sig = ""
        var centerTick = 0
        var searchTick = 0
        var wantUserOnce = false
        init(_ p: PlaceMap) { parent = p }

        /// 搜地名：先在当前视野附近找，找到第一个就把地图挪过去（结果坐标已是地图坐标，直接用）
        func search(_ q: String, in mv: MKMapView) {
            let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = s
            req.region = mv.region
            MKLocalSearch(request: req).start { [weak self] resp, _ in
                guard let self else { return }
                guard let item = resp?.mapItems.first else { self.parent.onSearchNote("没找到「\(s)」——换个写法试试"); return }
                mv.setRegion(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200), animated: true)
                self.parent.onSearchNote("跳到了「\(item.name ?? s)」，长按落钉")
            }
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let mv = map else { return }
            let c = mv.convert(g.location(in: mv), toCoordinateFrom: mv)   // 地图坐标（国内＝火星）
            parent.onLongPress(GeoShift.gcjToWgs(c))
        }
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard wantUserOnce, let l = userLocation.location else { return }
            wantUserOnce = false
            mapView.setRegion(MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 900, longitudinalMeters: 900), animated: false)
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let c = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKCircleRenderer(circle: c)
            let accent = UIColor(Theme.accent)
            if overlay is DraftCircle { r.fillColor = accent.withAlphaComponent(0.22); r.strokeColor = accent; r.lineWidth = 1.5 }
            else { r.fillColor = accent.withAlphaComponent(0.10); r.strokeColor = accent.withAlphaComponent(0.7); r.lineWidth = 1 }
            return r
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? PlacePin else { return nil }
            let id = "pin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView) ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
            v.annotation = pin
            v.markerTintColor = pin.pid == nil ? Theme.uiText : UIColor(Theme.accent)
            v.glyphImage = UIImage(named: "pin")
            v.titleVisibility = .visible
            v.displayPriority = .required
            v.canShowCallout = false
            return v
        }
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            defer { mapView.deselectAnnotation(view.annotation, animated: false) }
            guard let pin = view.annotation as? PlacePin, let pid = pin.pid, let p = parent.places.first(where: { $0.id == pid }) else { return }
            parent.onSelect(p)
        }
    }
}

/// 页面：整屏地图；长按落钉 → 底部小卡填名字/选半径（圆当场画）；点钉改名改半径/删；右下「到我这」。
struct PlacesScreen: View {
    var onBack: () -> Void
    @StateObject private var m = PlacesModel()
    @State private var draft: PlaceDraft? = Preview.on ? PlaceDraft(id: nil, lat: 30.6560, lon: 104.0850, radius: 150) : nil
    @State private var name = ""
    @State private var nameF = false
    @State private var saving = false
    @State private var centerTick = 0
    @State private var q = ""
    @State private var qF = false
    @State private var searchTick = 0
    @State private var searchNote = ""
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
                    Text("常去的地方 · \(m.places.count)").font(Theme.round(14)).foregroundColor(Theme.muted)
                    Spacer()
                    if !m.now.isEmpty { Text("此刻在：" + m.now).font(Theme.round(12)).foregroundColor(Theme.accent) }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                // 搜索框照抽屉那只：远的地方打名字跳过去，不用自己拖（寻 09-10）
                HStack(spacing: 0) {
                    PlainField(text: $q, focused: $qF, placeholder: "搜个地名跳过去…", font: Self.fieldFont, returnKey: .search, onSubmit: search)
                        .frame(height: 20).padding(.vertical, 7).padding(.horizontal, 12)
                    Button(action: search) {
                        Image("search").renderingMode(.template).resizable().frame(width: 15, height: 15).foregroundColor(.white)
                            .padding(.horizontal, 13).frame(height: 28)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).padding(3)
                }
                .frame(height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border, lineWidth: 0.7))
                .padding(.horizontal, 16).padding(.bottom, 8)
                Text(hint).font(Theme.round(11)).tracking(0.44).lineSpacing(3).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
                ZStack(alignment: .bottomTrailing) {
                    PlaceMap(places: m.places, draft: draft, centerTick: centerTick, searchQuery: q, searchTick: searchTick,
                             onLongPress: { c in startDraft(id: nil, lat: c.latitude, lon: c.longitude, radius: 100, name: "") },
                             onSelect: { p in startDraft(id: p.id, lat: p.lat, lon: p.lon, radius: p.radius, name: p.name) },
                             onSearchNote: { searchNote = $0 })
                        .ignoresSafeArea(edges: .bottom)
                    if draft == nil {
                        Button { centerTick += 1 } label: {
                            Image("locate").renderingMode(.template).resizable().frame(width: 18, height: 18).foregroundColor(.white)
                                .frame(width: 42, height: 42).background(Theme.accent, in: Circle())
                        }.buttonStyle(.plain).padding(.trailing, 16).padding(.bottom, 28)
                    }
                }
                .overlay(alignment: .bottom) { if draft != nil { editCard.padding(.horizontal, 14).padding(.bottom, 14) } }
                .transaction { $0.animation = nil }   // 小卡瞬间出现/消失（寻定：不滑不淡）
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .task { Fences.shared.requestAlways(); await m.load() }
    }

    private func search() {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        qF = false; searchTick += 1
    }

    private var hint: String {
        var s = !m.status.isEmpty ? m.status : (!searchNote.isEmpty ? searchNote : "长按地图落一个钉；点钉改名、改半径。圆就是围栏的边，蓝点该落在你站的地方。")
        if Fences.shared.authorization != .authorizedAlways { s += " 定位权限现在是「\(Fences.shared.authLabel)」，要离开手机也能报到，得在 设置→Keep→位置 里选「始终」。" }
        return s
    }

    private func startDraft(id: String?, lat: Double, lon: Double, radius: Int, name n: String) {
        draft = PlaceDraft(id: id, lat: lat, lon: lon, radius: radius); name = n; nameF = id == nil
    }

    private var hair: some View { Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1) }

    private var editCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlainField(text: $name, focused: $nameF, placeholder: "叫什么（家 / 学校 / 青羊宫…）", font: Self.fieldFont, returnKey: .done, onSubmit: { nameF = false })
                .frame(height: 20).padding(.vertical, 11).padding(.horizontal, 15)
            hair
            HStack(spacing: 6) {
                Text("半径").font(Theme.round(12)).foregroundColor(Theme.muted)
                ForEach([100, 150, 200, 300, 500], id: \.self) { r in
                    let on = draft?.radius == r
                    Button { draft?.radius = r } label: {
                        Text("\(r)").font(Theme.round(12, weight: on ? .medium : .regular))
                            .foregroundColor(on ? .white : Theme.muted)
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(on ? Theme.accent : Theme.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Text("米").font(Theme.round(12)).foregroundColor(Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            HStack(spacing: 14) {
                Button { draft = nil; nameF = false } label: { Text("取消").font(Theme.round(13)).foregroundColor(Theme.muted) }.buttonStyle(.plain)
                if let id = draft?.id, let p = m.places.first(where: { $0.id == id }) {
                    Button { Task { await m.remove(p); draft = nil } } label: { Text("删掉").font(Theme.round(13)).foregroundColor(Theme.muted) }.buttonStyle(.plain)
                }
                Spacer()
                Button {
                    guard let d = draft, !saving else { return }
                    saving = true; nameF = false
                    Task {
                        if await m.save(id: d.id, name: name, coord: CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon), radius: d.radius) { draft = nil }
                        saving = false
                    }
                } label: {
                    Text(saving ? "记着…" : (draft?.id == nil ? "记下" : "改好")).font(Theme.round(14, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 32)
                        .background(Theme.accent.opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1), in: Capsule())
                }.buttonStyle(.plain).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 15).padding(.bottom, 12)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }
}
