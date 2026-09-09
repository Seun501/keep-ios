import Foundation
import HealthKit
import CoreLocation
import UIKit

/// 健康原生化（09-08 寻定）：Keep 自己读健康库，照快捷指令那套键名与格式推给网关 `/api/health/push`，
/// 服务器一行不改（切觉/均值/纸条全在服务器）。两层触发：回前台读一次；健康库后台投递（新样本落库
/// 系统叫醒一小会儿——锁屏时健康库加密读不到，解锁后那次才成）。
/// 早上一次「昨天档」（睡眠原始 + 六项，12 点前，一天一次）；每次回前台一份「当下快照」（?today=1）。
@MainActor
final class HealthSync: NSObject, CLLocationManagerDelegate {
    static let shared = HealthSync()
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private let ud = UserDefaults.standard
    private var lastNow: Date = .distantPast
    private var busyNow = false       // 09-09 首验：观察器装上那一刻各自回调一次 + 回前台，同一秒推了六份；在飞时别再起
    private var busyMorning = false
    private var locMgr: CLLocationManager?
    private var locCont: CheckedContinuation<CLLocation?, Never>?

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType { HKQuantityType(id) }
    private var sleepType: HKCategoryType { HKCategoryType(.sleepAnalysis) }
    private var readTypes: Set<HKObjectType> {
        [sleepType, q(.heartRateVariabilitySDNN), q(.restingHeartRate), q(.stepCount),
         q(.activeEnergyBurned), q(.appleStandTime), q(.heartRate)]
    }

    // MARK: 授权 / 后台

    /// 第一次弹系统面板；之后静默。返回是否可用
    func requestAuth() async -> Bool {
        guard !Preview.on, Self.available else { return false }
        PushRegistrar.diag("health: requestAuth asking")
        let ok: Bool = await withCheckedContinuation { c in
            store.requestAuthorization(toShare: [], read: readTypes) { ok, err in
                PushRegistrar.diag("health: requestAuth ok=\(ok) err=\(err?.localizedDescription ?? "")")
                c.resume(returning: ok)
            }
        }
        return ok
    }

    /// 启动时装观察器 + 后台投递（每次启动都要装，系统才会在后台叫醒）
    func setupBackground() {
        guard !Preview.on, Self.available, observers.isEmpty else { return }
        let plan: [(HKSampleType, HKUpdateFrequency)] = [
            (sleepType, .immediate), (q(.heartRate), .hourly), (q(.stepCount), .hourly),
            (q(.heartRateVariabilitySDNN), .hourly),
        ]
        for (t, f) in plan {
            store.enableBackgroundDelivery(for: t, frequency: f) { _, _ in }
            let oq = HKObserverQuery(sampleType: t, predicate: nil) { [weak self] _, done, _ in
                Task { @MainActor in
                    guard let self else { done(); return }
                    if t == self.sleepType { await self.pushMorning() } else { await self.pushNow(minGap: 15 * 60) }
                    done()
                }
            }
            store.execute(oq); observers.append(oq)
        }
    }

    /// 回前台 / 首开：早上一次昨天档 + 当下快照
    func syncOnActive() async {
        PushRegistrar.diag("health: syncOnActive available=\(Self.available) token=\(Keychain.token != nil)")
        guard !Preview.on, Self.available, Keychain.token != nil else { return }
        await pushMorning()
        await pushNow(minGap: 60)
    }

    // MARK: 昨天档（一天一次）

    private var todayKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func pushMorning() async {
        let hour = Calendar.current.component(.hour, from: Date())
        // 09-09 三包都没见「start」：把门口的每个条件先报出来
        PushRegistrar.diag("health: morning enter hour=\(hour) busy=\(busyMorning) done=\(ud.string(forKey: "health.morningDay") ?? "-") today=\(todayKey) token=\(Keychain.token != nil)")
        guard Keychain.token != nil, !busyMorning else { return }
        // 服务器随时收昨天档（按昨天入档）；这里只限 18 点前——再晚就等明早，免得半夜把昨天档盖一遍
        guard hour < 18 else { return }
        guard ud.string(forKey: "health.morningDay") != todayKey else { return }
        busyMorning = true; defer { busyMorning = false }
        PushRegistrar.diag("health: morning start hour=\(hour)")   // 09-09 首验：整段一句诊断都没出，先摸到走到哪
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        let yday0 = cal.date(byAdding: .day, value: -1, to: today0)!
        var body: [String: Any] = [:]
        // 睡眠原始：最近 36 小时的段落，每行「值|开始|结束」（切觉/归日/午睡全交服务器）
        let sleep = await samples(sleepType, from: Date().addingTimeInterval(-36 * 3600), to: Date())
        let lines = sleep.compactMap { s -> String? in
            guard let c = s as? HKCategorySample else { return nil }
            return "\(Self.sleepName(c.value))|\(Self.iso(c.startDate))|\(Self.iso(c.endDate))"
        }
        if !lines.isEmpty { body["睡眠原始"] = lines.joined(separator: "\n") }
        PushRegistrar.diag("health: morning sleep samples=\(sleep.count)")
        // 六项（键名同快捷指令；HRV 取昨天各样本平均，静息心率取两天内最新）
        if let v = await mean(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: yday0, to: today0) { body["HRV"] = (v * 10).rounded() / 10 }
        if let v = await latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: cal.date(byAdding: .day, value: -2, to: today0)!, to: Date()) { body["静息心率"] = Int(v.rounded()) }
        if let v = await sum(.stepCount, unit: .count(), from: yday0, to: today0) { body["步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: yday0, to: today0) { body["活动能量"] = (v * 10).rounded() / 10 }
        if let v = await sum(.appleStandTime, unit: .minute(), from: yday0, to: today0) { body["站立分钟数"] = Int(v.rounded()) }
        guard !body.isEmpty else { PushRegistrar.diag("health: morning empty (sleepSamples=\(sleep.count))"); return }
        PushRegistrar.diag("health: morning keys=\(body.count), asking location")
        if let l = await location() { body["纬度"] = l.coordinate.latitude; body["经度"] = l.coordinate.longitude }
        PushRegistrar.diag("health: morning location done, posting")
        let code = await post(body, today: false)
        if code == 200 {
            ud.set(todayKey, forKey: "health.morningDay")
            PushRegistrar.diag("health: morning pushed keys=\(body.count) sleepLines=\(lines.count)")
        } else {
            PushRegistrar.diag("health: morning post failed code=\(code) keys=\(body.count) sleepLines=\(lines.count)")
        }
    }

    // MARK: 当下快照

    func pushNow(minGap: TimeInterval) async {
        guard Keychain.token != nil, !busyNow, Date().timeIntervalSince(lastNow) >= minGap else { return }
        busyNow = true; defer { busyNow = false }
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        var body: [String: Any] = [:]
        if let v = await sum(.stepCount, unit: .count(), from: today0, to: Date()) { body["今日步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: today0, to: Date()) { body["今日活动能量"] = (v * 10).rounded() / 10 }
        if let v = await latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: Date().addingTimeInterval(-30 * 60), to: Date()) { body["当前心率"] = Int(v.rounded()) }
        if let v = await latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: today0, to: Date()) { body["当前HRV"] = (v * 10).rounded() / 10 }
        guard !body.isEmpty else { return }
        if await post(body, today: true) == 200 {
            lastNow = Date()
            PushRegistrar.diag("health: now pushed keys=\(body.count)")
        }
    }

    // MARK: 网关

    /// 返回 HTTP 状态码；没发出去（序列化失败/超时/断网）= -1
    private func post(_ body: [String: Any], today: Bool) async -> Int {
        guard let token = Keychain.token else { return -1 }
        var url = Gateway.home.appendingPathComponent("api/health/push")
        if today { url = URL(string: url.absoluteString + "?today=1") ?? url }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else { return -2 }
        r.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return -1 }
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    // MARK: 查询（async 壳）

    private func samples(_ t: HKSampleType, from: Date, to: Date) async -> [HKSample] {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let s = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            store.execute(HKSampleQuery(sampleType: t, predicate: p, limit: HKObjectQueryNoLimit, sortDescriptors: [s]) { _, r, _ in c.resume(returning: r ?? []) })
        }
    }
    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
            store.execute(HKStatisticsQuery(quantityType: q(id), quantitySamplePredicate: p, options: .cumulativeSum) { _, s, _ in
                c.resume(returning: s?.sumQuantity()?.doubleValue(for: unit))
            })
        }
    }
    private func mean(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
            store.execute(HKStatisticsQuery(quantityType: q(id), quantitySamplePredicate: p, options: .discreteAverage) { _, s, _ in
                c.resume(returning: s?.averageQuantity()?.doubleValue(for: unit))
            })
        }
    }
    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let s = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            store.execute(HKSampleQuery(sampleType: q(id), predicate: p, limit: 1, sortDescriptors: [s]) { _, r, _ in
                c.resume(returning: (r?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            })
        }
    }

    // MARK: 位置（只在早上那次取一回；没权限就算了）

    private func location() async -> CLLocation? {
        let m = locMgr ?? CLLocationManager(); locMgr = m; m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization(); try? await Task.sleep(nanoseconds: 3_000_000_000) }
        guard m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways else { return nil }
        return await withCheckedContinuation { c in
            locCont = c; m.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.locCont?.resume(returning: nil); self?.locCont = nil }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in locCont?.resume(returning: locations.last); locCont = nil }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in locCont?.resume(returning: nil); locCont = nil }
    }

    // MARK: 格式

    private static let isoF: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f }()
    private static func iso(_ d: Date) -> String { isoF.string(from: d) }
    /// 阶段名同她手机快捷指令吐的英文（服务器 _parse_sleep_raw 认 awake/inbed/deep/rem）
    private static func sleepName(_ v: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: v) {
        case .inBed: return "InBed"
        case .awake: return "Awake"
        case .asleepCore: return "Core"
        case .asleepDeep: return "Deep"
        case .asleepREM: return "REM"
        default: return "Asleep"
        }
    }
}
