import Foundation
import CoreLocation
import MapKit
import UIKit

/// 给克的导航（09-15 寻定）第一层：她在位置页按「出发」——选目的地（常去的地方或搜到的地名）、选交通方式（每趟选）；
/// 路线和预计时间苹果地图算；网关记下这一趟，克查 health(now) 时手机顺手算好剩余路程，他那句变成「在去学校的路上，还剩 1.2 公里，约 15 分钟」；
/// 到目的地的围栏一进，网关排纸条「15:12-寻到了学校（路上 23 分钟）」。位置不常开，只在到站围栏和克来问时才取一次。
/// 「跟着你走、报下一步」那层（高德引擎）另做。
struct Trip: Codable, Equatable {
    var name: String
    var lat: Double          // GPS 坐标（同 Place）
    var lon: Double
    var mode: String         // 步行 / 骑行 / 公交 / 打车
    var startedAt: Date
    var etaMin: Int? = nil
    var distM: Int? = nil
    var placeId: String? = nil
    static let modes = ["步行", "骑行", "公交", "打车"]
}

@MainActor
final class TripModel: ObservableObject {
    static let shared = TripModel()
    @Published var current: Trip? = TripModel.cached() { didSet { TripModel.cache(current) } }
    @Published var busy = false

    private static func cached() -> Trip? {
        guard !Preview.on, let d = UserDefaults.standard.data(forKey: "trip.current") else { return nil }
        return try? JSONDecoder().decode(Trip.self, from: d)
    }
    private static func cache(_ t: Trip?) {
        if let t, let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: "trip.current") }
        else { UserDefaults.standard.removeObject(forKey: "trip.current") }
    }

    /// 启动时和网关对一遍（表上/别处结束了、或服务器那边到站了）
    func sync() async {
        guard !Preview.on, let req = Self.request("api/trip") else { return }
        guard let (d, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if j["trip"] == nil || j["trip"] is NSNull {
            if current != nil { current = nil; Fences.shared.watchTrip(nil) }
        } else if let t = current { Fences.shared.watchTrip(CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)) }
    }

    /// 出发：算一次路线（预计时间给克看），记到网关，装到站围栏
    func start(name: String, coord: CLLocationCoordinate2D, mode: String, placeId: String?) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        var t = Trip(name: name, lat: coord.latitude, lon: coord.longitude, mode: mode, startedAt: Date(), placeId: placeId)
        if let here = await Fences.shared.locate(accuracy: kCLLocationAccuracyHundredMeters, timeout: 6),
           let r = await Self.eta(from: here.coordinate, to: coord, mode: mode) {
            t.etaMin = r.min; t.distM = r.m
        }
        var body: [String: Any] = ["action": "start", "name": name, "lat": coord.latitude, "lon": coord.longitude, "mode": mode]
        if let e = t.etaMin { body["eta_min"] = e }
        if let m = t.distM { body["dist_m"] = m }
        if let p = placeId { body["place_id"] = p }
        guard await Self.post(body) else { return false }
        current = t
        Fences.shared.watchTrip(coord)
        PushRegistrar.diag("trip: start \(mode) eta=\(t.etaMin ?? -1)")
        return true
    }

    func stop() async {
        _ = await Self.post(["action": "stop"])
        current = nil
        Fences.shared.watchTrip(nil)
    }

    /// 到站围栏进了（Fences 调）
    func arrived() async {
        guard current != nil else { return }
        PushRegistrar.diag("trip: arrive")
        _ = await Self.post(["action": "arrive"])
        current = nil
        Fences.shared.watchTrip(nil)
    }

    /// 克来问时：从此刻位置到目的地还剩多少（苹果地图路线）
    func remaining(from here: CLLocation?) async -> (m: Int, min: Int)? {
        guard let t = current, let here else { return nil }
        return await Self.eta(from: here.coordinate, to: CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon), mode: t.mode)
    }

    /// 苹果地图的预计时间。坐标都是 GPS，国内底图要先挪成火星坐标再问路。骑行苹果没有，按步行路线、时间除 2.8
    static func eta(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, mode: String) async -> (m: Int, min: Int)? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: GeoShift.wgsToGcj(a)))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: GeoShift.wgsToGcj(b)))
        switch mode {
        case "公交": req.transportType = .transit
        case "打车": req.transportType = .automobile
        default: req.transportType = .walking
        }
        guard let r = try? await MKDirections(request: req).calculateETA() else { return nil }
        var secs = r.expectedTravelTime
        if mode == "骑行" { secs /= 2.8 }
        return (Int(r.distance), max(1, Int((secs / 60).rounded())))
    }

    private static func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path)); r.timeoutInterval = 15
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        return r
    }
    private static func post(_ body: [String: Any]) async -> Bool {
        if Preview.on { return true }
        guard let d = try? JSONSerialization.data(withJSONObject: body), let req = request("api/trip", method: "POST", body: d) else { return false }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "trip")
        defer { UIApplication.shared.endBackgroundTask(bg) }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
