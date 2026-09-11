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
    private var mensType: HKCategoryType { HKCategoryType(.menstrualFlow) }   // 月经（09-09 寻：接！）——值照快捷指令的中文
    private var readTypes: Set<HKObjectType> {
        [sleepType, mensType, q(.heartRateVariabilitySDNN), q(.restingHeartRate), q(.stepCount),
         q(.activeEnergyBurned), q(.appleStandTime), q(.heartRate),
         // 09-10 克要在每日块看到的三样：运动记录、腕温（表睡里测）、呼吸（表睡里测）
         q(.appleSleepingWristTemperature), q(.respiratoryRate), HKObjectType.workoutType()]
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
        Task { await self.backfill() }   // 历史回填：一次性，慢慢推，不挡上面两份
    }

    // MARK: 昨天档（一天一次）

    private var todayKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func pushMorning() async {
        let hour = Calendar.current.component(.hour, from: Date())
        // 09-09 三包都没见「start」：把门口的每个条件先报出来
        PushRegistrar.diag("health: morning enter hour=\(hour) busy=\(busyMorning) done=\(ud.string(forKey: "health.morningDay") ?? "-") today=\(todayKey) token=\(Keychain.token != nil)")
        guard Keychain.token != nil, !busyMorning else { return }
        // 服务器随时收昨天档（按昨天入档，同键合并）。窗口 6–18 点：09-11 栽过——00:10 她还醒着就推了昨天档，
        // 觉还没睡完，睡眠那几键就永远缺了。记的值带小时「yyyy-MM-dd@H」：若今天那次是半夜推的（旧值没小时也算），
        // 6 点后再补一次，不受 18 点限；补过就算数。
        let rec = (ud.string(forKey: "health.morningDay") ?? "").split(separator: "@")
        let recDay = rec.first.map(String.init) ?? ""
        let recHour = rec.count > 1 ? (Int(rec[1]) ?? 0) : 0
        guard hour >= 6 else { return }
        let retry = recDay == todayKey && recHour < 6
        guard retry || hour < 18 else { return }
        guard recDay != todayKey || retry else { return }
        busyMorning = true; defer { busyMorning = false }
        PushRegistrar.diag("health: morning start hour=\(hour)")   // 09-09 首验：整段一句诊断都没出，先摸到走到哪
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        let yday0 = cal.date(byAdding: .day, value: -1, to: today0)!
        var body = await dayBody(yday0)
        guard !body.isEmpty else { PushRegistrar.diag("health: morning empty"); return }
        PushRegistrar.diag("health: morning keys=\(body.count), asking location")
        if let l = await location() { body["纬度"] = l.coordinate.latitude; body["经度"] = l.coordinate.longitude }
        PushRegistrar.diag("health: morning location done, posting")
        let code = await post(body, today: false)
        if code == 200 {
            ud.set("\(todayKey)@\(hour)", forKey: "health.morningDay")
            PushRegistrar.diag("health: morning pushed keys=\(body.count) sleep=\(body["睡眠原始"] != nil)\(retry ? " (retry)" : "")")
        } else {
            PushRegistrar.diag("health: morning post failed code=\(code) keys=\(body.count)")
        }
    }

    /// 某一天的档（day0＝那天 0 点）。夜觉窗＝那天中午到次日中午（入睡−12小时归日的口径），
    /// 到不了次日中午就截到现在。昨天档和历史回填共用这一份，算法只写一遍。
    private func dayBody(_ day0: Date) async -> [String: Any] {
        let cal = Calendar.current
        let next0 = cal.date(byAdding: .day, value: 1, to: day0)!
        let noon = day0.addingTimeInterval(12 * 3600)
        let nightEnd = min(next0.addingTimeInterval(12 * 3600), Date())
        var body: [String: Any] = [:]
        // 睡眠原始：段落每行「值|开始|结束」（切觉/归日/午睡全交服务器）
        let sleep = await samples(sleepType, from: noon, to: nightEnd)
        let lines = sleep.compactMap { s -> String? in
            guard let c = s as? HKCategorySample else { return nil }
            return "\(Self.sleepName(c.value))|\(Self.iso(c.startDate))|\(Self.iso(c.endDate))"
        }
        if !lines.isEmpty { body["睡眠原始"] = lines.joined(separator: "\n") }
        // 六项（键名同快捷指令；HRV 取那天各样本平均，静息心率取那天的）
        if let v = await mean(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: day0, to: next0) { body["HRV"] = (v * 10).rounded() / 10 }
        if let r = await latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: day0, to: next0) { body["静息心率"] = Int(r.0.rounded()) }
        if let v = await sum(.stepCount, unit: .count(), from: day0, to: next0), v > 0 { body["步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: day0, to: next0), v > 0 { body["活动能量"] = (v * 10).rounded() / 10 }
        if let v = await sum(.appleStandTime, unit: .minute(), from: day0, to: next0), v > 0 { body["站立分钟数"] = Int(v.rounded()) }
        // 月经：那天记的最后一条（健康 App 里她自己记的），键名/词同快捷指令（无/轻微/中等/大量）
        if let m = (await samples(mensType, from: day0, to: next0)).last as? HKCategorySample, let w = Self.mensWord(m.value) { body["月经"] = w }
        // 09-10 克要的三样。腕温：表一晚一个值，取那晚的；呼吸：表只在睡里记，那晚的均值；
        // 运动：那天的体能训练，文字明细＋总分钟
        if let t = await latest(.appleSleepingWristTemperature, unit: .degreeCelsius(), from: noon, to: nightEnd) { body["腕温"] = (t.0 * 100).rounded() / 100 }
        if let v = await mean(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: noon, to: nightEnd) { body["呼吸"] = (v * 10).rounded() / 10 }
        let w = await workouts(from: day0, to: next0)
        if !w.isEmpty { body["运动"] = Self.workoutText(w); body["运动分钟"] = Int((w.reduce(0) { $0 + $1.duration } / 60).rounded()) }
        return body
    }

    // MARK: 历史回填（09-10 寻：「我以为可以拿到以前的健康数据」）

    /// 装上后一次：从前天起往回最多一年，一天一份按 date 推（?backfill=1 只入档不排纸条）。
    /// 进度落 UserDefaults，中途退到后台被挂起就下次接着推；连续 45 天空档＝表还没戴上，停。
    private static let backfillTag = "v1"
    private var busyBackfill = false
    private func backfill() async {
        guard Keychain.token != nil, !busyBackfill, ud.string(forKey: "health.backfillDone") != Self.backfillTag else { return }
        busyBackfill = true; defer { busyBackfill = false }
        // 服务器认得 ?backfill=1 了才开工（旧服务器会把一年前某晚当「昨晚」排睡眠纸条）
        guard await serverBackfillOK() else { PushRegistrar.diag("health: backfill waits for server"); return }
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        var i = max(2, ud.integer(forKey: "health.backfillNext"))
        var empties = 0, pushed = 0
        PushRegistrar.diag("health: backfill start from day-\(i)")
        while i <= 365 && empties < 45 {
            let day0 = cal.date(byAdding: .day, value: -i, to: today0)!
            var body = await dayBody(day0)
            if body.isEmpty {
                empties += 1
            } else {
                empties = 0
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                body["date"] = f.string(from: day0)
                let code = await post(body, today: false, backfill: true)
                guard code == 200 else { PushRegistrar.diag("health: backfill stop code=\(code) at day-\(i) pushed=\(pushed)"); return }
                pushed += 1
            }
            i += 1
            ud.set(i, forKey: "health.backfillNext")
        }
        ud.set(Self.backfillTag, forKey: "health.backfillDone")
        PushRegistrar.diag("health: backfill done pushed=\(pushed) lastDay=-\(i - 1)")
    }

    // MARK: 当下快照

    /// live=克在等（静默推送来的，09-09）：不看间隔、心率带样本钟点（`_心率测于`，服务器只记状态不入档）
    @discardableResult
    func pushNow(minGap: TimeInterval, live: Bool = false) async -> Bool {
        guard Keychain.token != nil, !busyNow, Date().timeIntervalSince(lastNow) >= minGap else { return false }
        busyNow = true; defer { busyNow = false }
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        async let whereT = Fences.shared.whereNow()   // 此刻在哪（坐标给服务器算离学校多远 + 本机反查的地名，09-10）——和健康库并行取，别拖慢克那边的等待
        var body: [String: Any] = [:]
        if let v = await sum(.stepCount, unit: .count(), from: today0, to: Date()) { body["今日步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: today0, to: Date()) { body["今日活动能量"] = (v * 10).rounded() / 10 }
        // 心率取两小时内最新一条并带钟点——「当前」到底是几分钟前的，克看得见
        if let hr = await latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: Date().addingTimeInterval(-2 * 3600), to: Date()) {
            body["当前心率"] = Int(hr.0.rounded()); body["_心率测于"] = Self.hm(hr.1)
        }
        if let hrv = await latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: today0, to: Date()) { body["当前HRV"] = (hrv.0 * 10).rounded() / 10 }
        let w = await workouts(from: today0, to: Date())
        if !w.isEmpty { body["今日运动"] = Self.workoutText(w) }
        let (whereText, whereLoc) = await whereT
        if let s = whereText { body["_位置"] = s }
        if let l = whereLoc {   // 「_」键＝随身元信息，只进状态不入档；克看到的是服务器算出的距离，不是这两个数
            body["_纬度"] = String(format: "%.5f", l.coordinate.latitude)
            body["_经度"] = String(format: "%.5f", l.coordinate.longitude)
        }
        guard !body.isEmpty else { PushRegistrar.diag("health: now empty live=\(live)"); return false }
        let code = await post(body, today: true)
        if code == 200 {
            lastNow = Date()
            PushRegistrar.diag("health: now pushed keys=\(body.count) live=\(live)")
            return true
        }
        PushRegistrar.diag("health: now post failed code=\(code) live=\(live)")
        return false
    }

    // MARK: 网关

    private func serverBackfillOK() async -> Bool {
        guard let token = Keychain.token else { return false }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/health/pushed_today")); r.timeoutInterval = 15
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (j["backfill_ok"] as? Bool) == true
    }

    /// 返回 HTTP 状态码；没发出去（序列化失败/超时/断网）= -1
    private func post(_ body: [String: Any], today: Bool, backfill: Bool = false) async -> Int {
        guard let token = Keychain.token else { return -1 }
        var url = Gateway.home.appendingPathComponent("api/health/push")
        if today { url = URL(string: url.absoluteString + "?today=1") ?? url }
        else if backfill { url = URL(string: url.absoluteString + "?backfill=1") ?? url }
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
    /// 窗口内最新一条：值 + 样本结束时刻
    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> (Double, Date)? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let s = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            store.execute(HKSampleQuery(sampleType: q(id), predicate: p, limit: 1, sortDescriptors: [s]) { _, r, _ in
                guard let x = r?.first as? HKQuantitySample else { c.resume(returning: nil); return }
                c.resume(returning: (x.quantity.doubleValue(for: unit), x.endDate))
            })
        }
    }

    /// 体能训练记录（按开始时刻落窗）
    private func workouts(from: Date, to: Date) async -> [HKWorkout] {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
            let s = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: p, limit: HKObjectQueryNoLimit, sortDescriptors: [s]) { _, r, _ in
                c.resume(returning: (r ?? []).compactMap { $0 as? HKWorkout })
            })
        }
    }

    /// 「16:20 跑步 32分（210千卡、均心率142）；18:05 步行 25分（80千卡）」——单行，服务器按文字原样存（≤200 字）
    private static func workoutText(_ ws: [HKWorkout]) -> String {
        ws.map { w -> String in
            var extras: [String] = []
            if let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), kcal >= 1 {
                extras.append("\(Int(kcal.rounded()))千卡")
            }
            if let hr = w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                extras.append("均心率\(Int(hr.rounded()))")
            }
            let mins = Int((w.duration / 60).rounded())
            return "\(hm(w.startDate)) \(activityName(w.workoutActivityType)) \(mins)分" + (extras.isEmpty ? "" : "（\(extras.joined(separator: "、"))）")
        }.joined(separator: "；")
    }

    private static func activityName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .swimming: return "游泳"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "力量训练"
        case .coreTraining: return "核心训练"
        case .elliptical: return "椭圆机"
        case .stairClimbing, .stairs: return "爬楼梯"
        case .dance, .socialDance, .cardioDance: return "舞蹈"
        case .pilates: return "普拉提"
        case .highIntensityIntervalTraining: return "高强度间歇"
        case .cooldown: return "放松"
        case .mindAndBody: return "身心"
        case .flexibility: return "拉伸"
        case .jumpRope: return "跳绳"
        case .tableTennis: return "乒乓球"
        case .badminton: return "羽毛球"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .tennis: return "网球"
        case .volleyball: return "排球"
        case .rowing: return "划船"
        case .kickboxing: return "搏击"
        case .boxing: return "拳击"
        case .martialArts: return "武术"
        case .taiChi: return "太极"
        case .climbing: return "攀岩"
        case .skatingSports: return "滑冰"
        case .crossTraining, .mixedCardio: return "混合训练"
        case .fitnessGaming: return "健身游戏"
        default: return "运动"
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
    private static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
    private static func mensWord(_ v: Int) -> String? {
        switch HKCategoryValueMenstrualFlow(rawValue: v) {
        case .light: return "轻微"
        case .medium: return "中等"
        case .heavy: return "大量"
        case .none: return "无"
        case .unspecified: return "有"
        default: return nil
        }
    }
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
