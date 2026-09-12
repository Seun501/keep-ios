import Foundation
import CoreLocation
import WeatherKit

/// 今天的紫外线最高（09-12 寻定：她手机天气 App 报 5、和风接口报 2，要一样的数只能读 Apple 天气）。
/// WeatherKit 只有手机能问；取到的数随起床档/快照带给网关（键 `_紫外线最高`，元信息不入档）。
/// 一天只问一次，存 UserDefaults；问不到（能力没开/断网）就不带，网关照旧退和风。
enum UVToday {
    private static let ud = UserDefaults.standard

    static func max(at loc: CLLocation) async -> Int? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        if ud.string(forKey: "uv.day") == today, let v = ud.object(forKey: "uv.max") as? Int { return v }
        do {
            let daily = try await WeatherService.shared.weather(for: loc, including: .daily)
            let cal = Calendar.current
            guard let day = daily.first(where: { cal.isDateInToday($0.date) }) ?? daily.first else { return nil }
            let v = day.uvIndex.value
            ud.set(today, forKey: "uv.day"); ud.set(v, forKey: "uv.max")
            return v
        } catch {
            PushRegistrar.diag("uv: weatherkit failed: \(error.localizedDescription)")
            return nil
        }
    }
}
