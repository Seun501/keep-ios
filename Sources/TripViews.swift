import SwiftUI
import MapKit
import CoreLocation

/// 位置页的「出发」卡（09-15，给克的导航第一层）：去哪（常去的地方一排胶囊，或搜个地名）、怎么去（每趟选）、出发。
/// 在路上时同一张卡变成「→ 学校 · 步行 · 约 18 分 · 14:02 出发」＋「结束」。样式照位置页的编辑小卡。
struct TripCard: View {
    @ObservedObject var m: PlacesModel
    var onClose: () -> Void
    @ObservedObject private var trip = TripModel.shared
    @State private var q = ""
    @State private var qF = false
    @State private var results: [(name: String, coord: CLLocationCoordinate2D)] = []
    @State private var picked: (name: String, coord: CLLocationCoordinate2D, placeId: String?)? = Preview.on ? ("学校", CLLocationCoordinate2D(latitude: 30.656, longitude: 104.085), "p1") : nil
    @State private var mode = "步行"
    @State private var note = ""
    private static let fieldFont: UIFont = Theme.uiRound(14)
    private var hair: some View { Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let t = trip.current { onTheWay(t) } else { planning }
        }
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairRing, lineWidth: 1.5))
        .shadow(color: Color.black.opacity(0.09), radius: 19, y: 14)
    }

    // MARK: 在路上
    private func onTheWay(_ t: Trip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("→ \(t.name)").font(Theme.round(15, weight: .medium)).foregroundColor(Theme.text)
                Text(t.mode).font(Theme.round(12)).foregroundColor(Theme.muted)
                if let e = t.etaMin { Text("约 \(e) 分").font(Theme.mono(12)).foregroundColor(Theme.muted) }
                Spacer()
                Text(TimeFmt.hm(ISO8601DateFormatter().string(from: t.startedAt)) + " 出发").font(Theme.mono(12)).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            hair
            HStack {
                Text("到了目的地会自己告诉克；他中途问，也答得上还剩多远。").font(Theme.round(11)).foregroundColor(Theme.muted)
                Spacer()
                Button { Task { await trip.stop(); onClose() } } label: {
                    Text("结束").font(Theme.round(13)).foregroundColor(Theme.accent)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
        }
    }

    // MARK: 出发前
    private var planning: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 去哪：搜地名
            HStack(spacing: 0) {
                PlainField(text: $q, focused: $qF, placeholder: "去哪（搜个地名）", font: Self.fieldFont, returnKey: .search, selectAllOnFocus: true, onSubmit: search)
                    .frame(height: 20).padding(.vertical, 11).padding(.horizontal, 15)
                if picked != nil {
                    Text(picked!.name).font(Theme.round(12, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 10).frame(height: 24).background(Theme.accent, in: Capsule())
                        .padding(.trailing, 12)
                }
            }
            if !results.isEmpty {
                ForEach(Array(results.prefix(4).enumerated()), id: \.offset) { _, r in
                    Button { picked = (r.name, r.coord, nil); results = []; q = r.name; qF = false } label: {
                        Text(r.name).font(Theme.round(13)).foregroundColor(Theme.text).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 7)
                    }.buttonStyle(.plain)
                }
            }
            hair
            // 常去的地方：一排胶囊
            if !m.places.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(m.places) { p in
                            let on = picked?.placeId == p.id
                            Button { picked = (p.name, CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), p.id); results = []; q = "" } label: {
                                Text(p.name).font(Theme.round(12, weight: on ? .medium : .regular))
                                    .foregroundColor(on ? .white : Theme.muted)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(on ? Theme.accent : Theme.bg, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 15).padding(.vertical, 10)
                }
                hair
            }
            // 怎么去：每趟选（寻 09-15 定）
            HStack(spacing: 6) {
                ForEach(Trip.modes, id: \.self) { md in
                    let on = mode == md
                    Button { mode = md } label: {
                        Text(md).font(Theme.round(12, weight: on ? .medium : .regular))
                            .foregroundColor(on ? .white : Theme.muted)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(on ? Theme.accent : Theme.bg, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            HStack(spacing: 14) {
                Button { onClose() } label: { Text("取消").font(Theme.round(13)).foregroundColor(Theme.muted) }.buttonStyle(.plain)
                if !note.isEmpty { Text(note).font(Theme.round(11)).foregroundColor(Theme.muted).lineLimit(1) }
                Spacer()
                Button {
                    guard let p = picked, !trip.busy else { return }
                    Task {
                        if await trip.start(name: p.name, coord: p.coord, mode: mode, placeId: p.placeId) { note = "" } else { note = "没记上，再按一次" }
                    }
                } label: {
                    Text(trip.busy ? "算路线…" : "出发").font(Theme.round(14, weight: .medium)).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 32)
                        .background(Theme.accent.opacity(picked == nil ? 0.45 : 1), in: Capsule())
                }.buttonStyle(.plain).disabled(picked == nil || trip.busy)
            }
            .padding(.horizontal, 15).padding(.bottom, 12)
        }
    }

    /// 搜地名（苹果地图；结果是地图坐标，存成 GPS 坐标同 Place）
    private func search() {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        qF = false
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = s
        let anchor = m.places.first.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? CLLocationCoordinate2D(latitude: 30.67, longitude: 104.07)
        req.region = MKCoordinateRegion(center: GeoShift.wgsToGcj(anchor), latitudinalMeters: 30000, longitudinalMeters: 30000)
        MKLocalSearch(request: req).start { resp, _ in
            let items = resp?.mapItems ?? []
            DispatchQueue.main.async {
                results = items.prefix(4).map { ($0.name ?? s, GeoShift.gcjToWgs($0.placemark.coordinate)) }
                note = items.isEmpty ? "没找到「\(s)」" : ""
            }
        }
    }
}

/// 主页门楣底下那一条（在路上才有）：「→ 学校 · 步行 · 约 18 分」，点一下去位置页
struct TripStrip: View {
    let trip: Trip
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text("→ \(trip.name)").font(Theme.round(12, weight: .medium)).foregroundColor(Theme.accent)
                Text("·").foregroundColor(Theme.muted)
                Text(trip.mode).font(Theme.round(12)).foregroundColor(Theme.muted)
                if let e = trip.etaMin {
                    Text("·").foregroundColor(Theme.muted)
                    Text("约 \(e) 分").font(Theme.mono(12)).foregroundColor(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
