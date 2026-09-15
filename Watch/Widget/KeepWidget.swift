import WidgetKit
import SwiftUI

/// 表盘复杂功能（09-15 寻定：表上找 Keep 太费事）：圆的、角上的、矩形的、行内的都放一个「克」，点一下直接进对话页。
/// 静态的——不读对话（读要 App Group，另一次再说）；矩形那格写一行「和克说话」。
struct KeepEntry: TimelineEntry { let date: Date }

struct KeepProvider: TimelineProvider {
    func placeholder(in context: Context) -> KeepEntry { KeepEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (KeepEntry) -> Void) { completion(KeepEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<KeepEntry>) -> Void) {
        completion(Timeline(entries: [KeepEntry(date: .now)], policy: .never))
    }
}

struct KeepComplicationView: View {
    @Environment(\.widgetFamily) private var family
    private let ke = Font.system(size: 22, weight: .semibold, design: .serif)
    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack { AccessoryWidgetBackground(); Text("克").font(ke) }
        case .accessoryCorner:
            Text("克").font(.system(size: 20, weight: .semibold, design: .serif)).widgetLabel { Text("Keep") }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Text("克").font(ke)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep").font(.system(size: 14, weight: .semibold))
                    Text("和克说话").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            Text("Keep · 克")
        }
    }
}

struct KeepComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeepComplication", provider: KeepProvider()) { _ in
            KeepComplicationView().containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Keep")
        .description("点一下和克说话")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct KeepWidgetBundle: WidgetBundle {
    var body: some Widget { KeepComplication() }
}
