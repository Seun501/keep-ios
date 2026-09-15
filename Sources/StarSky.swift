import SwiftUI
import CoreLocation

/// 纸上的真星图（09-15 寻定，口令页的炫技）：此刻头顶那片天——按日期、时刻、所在地本地算出的真实恒星方位，不联网。
/// 亮星表六十来颗（J2000 赤经小时/赤纬度/视星等），天顶投影在屏高 40% 处，地平线在屏外，靠地平线的星淡出。
/// 白天是空的纸；太阳落到地平线下 6° 起星才全出来（0°→-8° 渐显）。口令对了那一瞬星座线连起来（lit 0→1），然后进屋。
enum StarSky {
    typealias Star = (ra: Double, dec: Double, mag: Double)
    static let stars: [String: Star] = [
        "Vega": (18.615, 38.78, 0.03), "Altair": (19.846, 8.87, 0.77), "Deneb": (20.690, 45.28, 1.25), "Sadr": (20.370, 40.26, 2.2), "Gienah": (20.770, 33.97, 2.5), "DeltaCyg": (19.750, 45.13, 2.9), "Albireo": (19.512, 27.96, 3.1),
        "Sheliak": (18.835, 33.36, 3.5), "Sulafat": (18.982, 32.69, 3.2), "Tarazed": (19.771, 10.61, 2.7), "Alshain": (19.922, 6.41, 3.7),
        "Arcturus": (14.261, 19.18, -0.05), "Izar": (14.750, 27.07, 2.4), "Alphecca": (15.578, 26.71, 2.2), "Rasalhague": (17.582, 12.56, 2.1), "Kornephoros": (16.503, 21.49, 2.8), "Eltanin": (17.943, 51.49, 2.2),
        "Antares": (16.490, -26.43, 1.06), "Dschubba": (16.006, -22.62, 2.3), "Sargas": (17.622, -43.00, 1.9), "Shaula": (17.560, -37.10, 1.6), "KausAus": (18.403, -34.38, 1.8), "Nunki": (18.921, -26.30, 2.0),
        "Spica": (13.420, -11.16, 0.98), "Polaris": (2.530, 89.26, 1.98),
        "Dubhe": (11.062, 61.75, 1.8), "Merak": (11.031, 56.38, 2.4), "Phecda": (11.897, 53.69, 2.4), "Megrez": (12.257, 57.03, 3.3), "Alioth": (12.900, 55.96, 1.8), "Mizar": (13.399, 54.93, 2.2), "Alkaid": (13.792, 49.31, 1.9),
        "Schedar": (0.675, 56.54, 2.2), "Caph": (0.153, 59.15, 2.3), "GamCas": (0.945, 60.72, 2.5), "Ruchbah": (1.430, 60.24, 2.7), "Segin": (1.907, 63.67, 3.4), "Alderamin": (21.310, 62.59, 2.4),
        "Alpheratz": (0.140, 29.09, 2.06), "Mirach": (1.162, 35.62, 2.05), "Almach": (2.065, 42.33, 2.1), "Markab": (23.079, 15.21, 2.5), "Scheat": (23.063, 28.08, 2.4), "Algenib": (0.220, 15.18, 2.8), "Enif": (21.736, 9.875, 2.4),
        "Hamal": (2.120, 23.46, 2.0), "Algol": (3.136, 40.96, 2.1), "Mirfak": (3.405, 49.86, 1.8), "Fomalhaut": (22.961, -29.62, 1.16), "DenebAlgedi": (21.784, -16.13, 2.9),
        "Capella": (5.278, 46.00, 0.08), "Menkalinan": (5.992, 44.95, 1.9), "Aldebaran": (4.599, 16.51, 0.85), "Elnath": (5.438, 28.61, 1.65), "Pleiades": (3.79, 24.1, 1.6),
        "Betelgeuse": (5.919, 7.41, 0.5), "Rigel": (5.242, -8.20, 0.13), "Bellatrix": (5.419, 6.35, 1.6), "Saiph": (5.796, -9.67, 2.1), "Alnitak": (5.679, -1.94, 1.7), "Alnilam": (5.604, -1.20, 1.7), "Mintaka": (5.533, -0.30, 2.2),
        "Sirius": (6.752, -16.72, -1.46), "Adhara": (6.977, -28.97, 1.5), "Procyon": (7.655, 5.22, 0.34), "Pollux": (7.755, 28.03, 1.14), "Castor": (7.577, 31.89, 1.58), "Alhena": (6.629, 16.40, 1.9),
        "Regulus": (10.140, 11.97, 1.35), "Denebola": (11.818, 14.57, 2.1), "Algieba": (10.333, 19.84, 2.0),
    ]
    static let lines: [[String]] = [
        ["Vega", "Deneb", "Altair", "Vega"],
        ["Deneb", "Sadr", "Albireo"], ["Gienah", "Sadr", "DeltaCyg"],
        ["Vega", "Sheliak", "Sulafat", "Vega"], ["Tarazed", "Altair", "Alshain"],
        ["Dubhe", "Merak", "Phecda", "Megrez", "Alioth", "Mizar", "Alkaid"], ["Megrez", "Dubhe"],
        ["Caph", "Schedar", "GamCas", "Ruchbah", "Segin"],
        ["Markab", "Scheat", "Alpheratz", "Algenib", "Markab"], ["Alpheratz", "Mirach", "Almach"],
        ["Dschubba", "Antares", "Sargas", "Shaula"],
        ["Betelgeuse", "Bellatrix", "Mintaka", "Alnilam", "Alnitak", "Saiph", "Rigel"], ["Mintaka", "Rigel"], ["Betelgeuse", "Alnitak"],
        ["Aldebaran", "Elnath"], ["Castor", "Pollux", "Alhena"], ["Regulus", "Algieba", "Denebola", "Regulus"],
        ["Capella", "Menkalinan"], ["Arcturus", "Izar"], ["Sirius", "Adhara"],
    ]

    static let defaultLat = 30.67, defaultLon = 104.07   // 没定位权限时按成都算

    /// 当地恒星时（度）
    static func lst(_ date: Date, lon: Double) -> Double {
        let d = date.timeIntervalSince(Date(timeIntervalSince1970: 946_728_000)) / 86400   // J2000.0 = 2000-01-01 12:00 UT
        let c = Calendar(identifier: .gregorian)
        var cal = c; cal.timeZone = TimeZone(identifier: "UTC")!
        let ut = Double(cal.component(.hour, from: date)) + Double(cal.component(.minute, from: date)) / 60 + Double(cal.component(.second, from: date)) / 3600
        return (100.46 + 0.985647 * d + lon + 15 * ut).truncatingRemainder(dividingBy: 360)
    }

    /// 赤道坐标 → 地平坐标（高度、方位，度；方位北 0 东 90）
    static func altAz(ra: Double, dec: Double, date: Date, lat: Double, lon: Double) -> (alt: Double, az: Double) {
        let R = Double.pi / 180
        let ha = (lst(date, lon: lon) - ra * 15) * R, de = dec * R, la = lat * R
        let alt = asin(sin(de) * sin(la) + cos(de) * cos(la) * cos(ha))
        let az = atan2(-sin(ha) * cos(de), sin(de) * cos(la) - cos(de) * sin(la) * cos(ha))
        return (alt / R, (az / R + 360).truncatingRemainder(dividingBy: 360))
    }

    /// 太阳高度（度）：低精度太阳位置，够判昼夜
    static func sunAlt(date: Date, lat: Double, lon: Double) -> Double {
        let R = Double.pi / 180
        let d = date.timeIntervalSince(Date(timeIntervalSince1970: 946_728_000)) / 86400
        let g = (357.529 + 0.98560028 * d) * R
        let q = 280.459 + 0.98564736 * d
        let L = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * R
        let e = (23.439 - 0.00000036 * d) * R
        let ra = atan2(cos(e) * sin(L), cos(L)) / R / 15
        let dec = asin(sin(e) * sin(L)) / R
        return altAz(ra: ra, dec: dec, date: date, lat: lat, lon: lon).alt
    }

    /// 星出来的程度 0…1：太阳 0° 以上＝0，-8° 以下＝1
    static func nightness(date: Date, lat: Double, lon: Double) -> Double {
        min(1, max(0, -sunAlt(date: date, lat: lat, lon: lon) / 8))
    }

    /// 所在地：有定位权限就用系统缓存的最后位置，没有按成都
    static func here() -> (Double, Double) {
        let m = CLLocationManager()
        if [.authorizedAlways, .authorizedWhenInUse].contains(m.authorizationStatus), let l = m.location { return (l.coordinate.latitude, l.coordinate.longitude) }
        return (defaultLat, defaultLon)
    }
}

/// 画在整页底上的星图。lit：星座线连起来的进度（0 没有线，1 全连上）。
struct StarSkyView: View {
    var date: Date
    var lat: Double
    var lon: Double
    var night: Double          // 0…1
    var lit: Double            // 0…1
    var body: some View {
        Canvas { g, size in
            guard night > 0 else { return }
            let R = Double.pi / 180
            // sim-255：天顶放大得太厉害，夏季大三角撑满半屏、线压在 Clawd 和输入线上——地平线半径收到 1.2 倍屏宽，多露一圈天、星座小一号
            let horizon = size.width * 1.2               // 地平线半径（屏外）
            let zenith = CGPoint(x: size.width / 2, y: size.height * 0.38)
            var pos: [String: (CGPoint, Double, Double)] = [:]
            for (k, s) in StarSky.stars {
                let (alt, az) = StarSky.altAz(ra: s.ra, dec: s.dec, date: date, lat: lat, lon: lon)
                guard alt > 8 else { continue }
                let r = (90 - alt) / 90 * horizon
                pos[k] = (CGPoint(x: zenith.x - r * sin(az * R), y: zenith.y - r * cos(az * R)), alt, s.mag)   // 看天：东在左
            }
            if lit > 0 {
                for seg in StarSky.lines {
                    for i in 0..<(seg.count - 1) {
                        guard let a = pos[seg[i]], let b = pos[seg[i + 1]] else { continue }
                        var p = Path(); p.move(to: a.0)
                        p.addLine(to: CGPoint(x: a.0.x + (b.0.x - a.0.x) * lit, y: a.0.y + (b.0.y - a.0.y) * lit))
                        g.stroke(p, with: .color(Theme.accent.opacity((0.18 + 0.5 * lit) * night)), lineWidth: 0.8)
                    }
                }
            }
            for (_, v) in pos {
                let (p, alt, mag) = v
                let r = max(0.7, 2.6 - 0.55 * mag)
                let fade = min(1, (alt - 8) / 22)
                let a = (0.45 + 0.45 * (1 - min(mag, 3) / 3)) * fade * night
                g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Theme.dyn(0xB9AE9F, 0xE8DCC8).opacity(a)))
            }
        }
        .allowsHitTesting(false)
    }
}
