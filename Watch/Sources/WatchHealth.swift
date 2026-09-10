import Foundation
import HealthKit
import WatchKit

/// 表上读健康库直推网关（算法与手机端 Health.swift 同一份口径，键名同）。
/// 昨天档：一天一次，只在「昨晚的觉已经结束」（最后一段睡眠结束 ≥30 分钟前）才带睡眠原始——
/// 表在她睡着时也能跑后台班，不加这道门会把半夜的半截觉当成「起床了」推出去。
/// 快照：隔 ≥15 分钟一份（后台班每小时一班，实际几班由系统给）。
@MainActor
final class WatchHealth: ObservableObject {
    static let shared = WatchHealth()
    @Published var status = "还没同步过"
    private let store = HKHealthStore()
    private let ud = UserDefaults.standard
    private var busy = false
    private var lastNow: Date = .distantPast

    private func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType { HKQuantityType(id) }
    private var sleepType: HKCategoryType { HKCategoryType(.sleepAnalysis) }
    private var mensType: HKCategoryType { HKCategoryType(.menstrualFlow) }
    private var readTypes: Set<HKObjectType> {
        [sleepType, mensType, q(.heartRateVariabilitySDNN), q(.restingHeartRate), q(.stepCount),
         q(.activeEnergyBurned), q(.appleStandTime), q(.heartRate),
         q(.appleSleepingWristTemperature), q(.respiratoryRate), HKObjectType.workoutType()]
    }

    // MARK: 班次

    /// 下一班：06:50 到 11:50 每小时一班（等她的觉结束好推昨天档），其余时段一小时一班快照
    func scheduleRefresh() {
        let cal = Calendar.current
        let now = Date()
        var next = now.addingTimeInterval(3600)
        if let m = cal.date(bySettingHour: 6, minute: 50, second: 0, of: now), m > now, m < next { next = m }
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: next, userInfo: nil) { _ in }
    }

    func sync(reason: String, force: Bool = false) async {
        guard WatchKeychain.token != nil, !busy else { return }
        busy = true; defer { busy = false }
        guard HKHealthStore.isHealthDataAvailable() else { status = "这块表读不到健康库"; return }
        let ok: Bool = await withCheckedContinuation { c in
            store.requestAuthorization(toShare: [], read: readTypes) { ok, _ in c.resume(returning: ok) }
        }
        guard ok else { status = "没拿到健康库权限"; WatchDiag.send("health: auth denied (\(reason))"); return }
        await pushMorning(reason: reason)
        await pushNow(minGap: force ? 0 : 15 * 60, reason: reason)
    }

    // MARK: 昨天档

    private var todayKey: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    private func pushMorning(reason: String) async {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 18, ud.string(forKey: "watch.morningDay") != todayKey else { return }
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        let yday0 = cal.date(byAdding: .day, value: -1, to: today0)!
        // 昨晚的觉结束了没：最后一段睡眠的结束时刻离现在 ≥30 分钟才算；没段落＝还没写进库，也不带
        let sleep = await samples(sleepType, from: yday0.addingTimeInterval(12 * 3600), to: Date())
        let sleepOver = (sleep.last?.endDate).map { Date().timeIntervalSince($0) >= 30 * 60 } ?? false
        var body = await dayBody(yday0, withSleep: sleepOver, sleep: sleep)
        guard !body.isEmpty else { WatchDiag.send("health: morning empty (\(reason))"); return }
        body["_来自"] = "watch"
        let code = await post(body, today: false)
        if code == 200 {
            // 觉还没结束＝只推了白天那些数字，今天晚些班次还会再来带睡眠
            if sleepOver { ud.set(todayKey, forKey: "watch.morningDay") }
            status = "昨天档 \(Self.hm(Date())) 推过了" + (sleepOver ? "" : "（等觉睡完再补睡眠）")
            WatchDiag.send("health: morning pushed keys=\(body.count) sleep=\(sleepOver) (\(reason))")
        } else {
            WatchDiag.send("health: morning post failed code=\(code) (\(reason))")
        }
    }

    private func dayBody(_ day0: Date, withSleep: Bool, sleep: [HKSample]) async -> [String: Any] {
        let cal = Calendar.current
        let next0 = cal.date(byAdding: .day, value: 1, to: day0)!
        let noon = day0.addingTimeInterval(12 * 3600)
        let nightEnd = min(next0.addingTimeInterval(12 * 3600), Date())
        var body: [String: Any] = [:]
        if withSleep {
            let lines = sleep.compactMap { s -> String? in
                guard let c = s as? HKCategorySample else { return nil }
                return "\(Self.sleepName(c.value))|\(Self.iso(c.startDate))|\(Self.iso(c.endDate))"
            }
            if !lines.isEmpty { body["睡眠原始"] = lines.joined(separator: "\n") }
            if let t = await latest(.appleSleepingWristTemperature, unit: .degreeCelsius(), from: noon, to: nightEnd) { body["腕温"] = (t * 100).rounded() / 100 }
            if let v = await mean(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: noon, to: nightEnd) { body["呼吸"] = (v * 10).rounded() / 10 }
        }
        if let v = await mean(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: day0, to: next0) { body["HRV"] = (v * 10).rounded() / 10 }
        if let r = await latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: day0, to: next0) { body["静息心率"] = Int(r.rounded()) }
        if let v = await sum(.stepCount, unit: .count(), from: day0, to: next0), v > 0 { body["步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: day0, to: next0), v > 0 { body["活动能量"] = (v * 10).rounded() / 10 }
        if let v = await sum(.appleStandTime, unit: .minute(), from: day0, to: next0), v > 0 { body["站立分钟数"] = Int(v.rounded()) }
        if let m = (await samples(mensType, from: day0, to: next0)).last as? HKCategorySample, let w = Self.mensWord(m.value) { body["月经"] = w }
        let w = await workouts(from: day0, to: next0)
        if !w.isEmpty { body["运动"] = Self.workoutText(w); body["运动分钟"] = Int((w.reduce(0) { $0 + $1.duration } / 60).rounded()) }
        return body
    }

    // MARK: 快照

    private func pushNow(minGap: TimeInterval, reason: String) async {
        guard Date().timeIntervalSince(lastNow) >= minGap else { return }
        let cal = Calendar.current
        let today0 = cal.startOfDay(for: Date())
        var body: [String: Any] = [:]
        if let v = await sum(.stepCount, unit: .count(), from: today0, to: Date()) { body["今日步数"] = Int(v.rounded()) }
        if let v = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: today0, to: Date()) { body["今日活动能量"] = (v * 10).rounded() / 10 }
        if let hr = await latestAt(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: Date().addingTimeInterval(-2 * 3600), to: Date()) {
            body["当前心率"] = Int(hr.0.rounded()); body["_心率测于"] = Self.hm(hr.1)
        }
        if let hrv = await latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: today0, to: Date()) { body["当前HRV"] = (hrv * 10).rounded() / 10 }
        let w = await workouts(from: today0, to: Date())
        if !w.isEmpty { body["今日运动"] = Self.workoutText(w) }
        guard !body.isEmpty else { return }
        body["_来自"] = "watch"
        let code = await post(body, today: true)
        if code == 200 {
            lastNow = Date()
            status = "快照 \(Self.hm(Date())) 推过了"
            WatchDiag.send("health: now pushed keys=\(body.count) (\(reason))")
        } else {
            WatchDiag.send("health: now post failed code=\(code) (\(reason))")
        }
    }

    // MARK: 网关

    private func post(_ body: [String: Any], today: Bool) async -> Int {
        guard let token = WatchKeychain.token else { return -1 }
        var url = WatchGateway.home.appendingPathComponent("api/health/push")
        if today { url = URL(string: url.absoluteString + "?today=1") ?? url }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 25
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else { return -2 }
        r.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: r) else { return -1 }
        return (resp as? HTTPURLResponse)?.statusCode ?? -1
    }

    // MARK: 查询

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
    private func latestAt(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> (Double, Date)? {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            let s = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            store.execute(HKSampleQuery(sampleType: q(id), predicate: p, limit: 1, sortDescriptors: [s]) { _, r, _ in
                guard let x = r?.first as? HKQuantitySample else { c.resume(returning: nil); return }
                c.resume(returning: (x.quantity.doubleValue(for: unit), x.endDate))
            })
        }
    }
    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        await latestAt(id, unit: unit, from: from, to: to)?.0
    }
    private func workouts(from: Date, to: Date) async -> [HKWorkout] {
        await withCheckedContinuation { c in
            let p = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
            let s = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            store.execute(HKSampleQuery(sampleType: .workoutType(), predicate: p, limit: HKObjectQueryNoLimit, sortDescriptors: [s]) { _, r, _ in
                c.resume(returning: (r ?? []).compactMap { $0 as? HKWorkout })
            })
        }
    }

    // MARK: 格式（同手机端）

    private static let isoF: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f }()
    private static func iso(_ d: Date) -> String { isoF.string(from: d) }
    static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
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
}
