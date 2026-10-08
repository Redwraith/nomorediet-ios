import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NomoredietWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        RestTimerLiveActivity()
    }
}

// MARK: - Home screen widget: protein and calories left, one-tap repeat

struct TodayEntry: TimelineEntry {
    let date: Date
    let summary: SharedStore.Summary?
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, summary: .init(kcalLeft: 850, kcalGoal: 2000, proteinLeft: 62, proteinGoal: 150, level: 3,
                                              favorites: [.init(key: "", dish: "Yogurt e avena", kcal: 380)], updated: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TodayEntry(date: .now, summary: SharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = TodayEntry(date: .now, summary: SharedStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private let accent = Color(red: 0.17, green: 0.42, blue: 0.30)
private let protein = Color(red: 0.77, green: 0.32, blue: 0.23)

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        Group {
            if let s = entry.summary, Calendar.current.isDateInToday(s.updated) {
                if family == .systemSmall { small(s) } else { medium(s) }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "fork.knife.circle.fill").font(.largeTitle).foregroundStyle(accent)
                    Text("Apri Nomorediet").font(.headline)
                    Text("per vedere la giornata").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "nomorediet://diario"))
    }

    private func ring(_ s: SharedStore.Summary) -> some View {
        let done = s.proteinGoal > 0 ? Double(s.proteinGoal - s.proteinLeft) / Double(s.proteinGoal) : 0
        return ZStack {
            Circle().stroke(protein.opacity(0.18), lineWidth: 9)
            Circle().trim(from: 0, to: max(0.02, min(1, done)))
                .stroke(protein, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(max(0, s.proteinLeft))").font(.system(size: 26, weight: .heavy, design: .rounded))
                Text("g proteine").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func small(_ s: SharedStore.Summary) -> some View {
        VStack(spacing: 8) {
            ring(s).frame(width: 92, height: 92)
            Text(s.kcalLeft >= 0 ? "\(s.kcalLeft) kcal rimaste" : "\(-s.kcalLeft) kcal oltre")
                .font(.caption.weight(.semibold))
        }
    }

    private func medium(_ s: SharedStore.Summary) -> some View {
        HStack(spacing: 14) {
            ring(s).frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.kcalLeft >= 0 ? "\(s.kcalLeft) kcal rimaste" : "\(-s.kcalLeft) kcal oltre")
                    .font(.headline)
                ForEach(s.favorites.prefix(2), id: \.self) { fav in
                    Link(destination: URL(string: "nomorediet://repeat?key=\(fav.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")")!) {
                        Label("Ripeti \(fav.dish)", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(accent.opacity(0.14), in: Capsule())
                    }
                }
                Link(destination: URL(string: "nomorediet://photo")!) {
                    Label("Foto pasto", systemImage: "camera.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accent, in: Capsule()).foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NomoredietToday", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Oggi")
            .description("Proteine e calorie che ti mancano, con i pasti da ripetere.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Rest timer Live Activity

struct RestTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RestTimerAttributes.self) { context in
            RestTimerLockView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recupero", systemImage: "timer").font(.caption).foregroundStyle(accent).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context.state.end)
                        .font(.title2.weight(.heavy)).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(maxWidth: 90, alignment: .trailing).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.next.isEmpty ? "Timer" : "Poi: \(context.state.next)").font(.caption).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "timer").foregroundStyle(accent)
            } compactTrailing: {
                countdown(context.state.end)
                    .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(accent)
            }
        }
        // Apple Watch Smart Stack (watchOS 11+) and CarPlay use the small layout
        .supplementalActivityFamilies([.small, .medium])
    }
}

private func countdown(_ end: Date) -> Text {
    Text(timerInterval: Date.now...max(Date.now, end), countsDown: true)
}

/// Lock screen / banner, and the small layout shown on Apple Watch.
struct RestTimerLockView: View {
    @Environment(\.activityFamily) private var family
    let state: RestTimerAttributes.ContentState

    var body: some View {
        if family == .small {
            // Apple Watch: black on white, readable at a glance
            VStack(alignment: .leading, spacing: 2) {
                Label(state.next.isEmpty ? "Timer" : "Recupero", systemImage: "timer").font(.caption2.weight(.semibold))
                countdown(state.end).font(.system(size: 32, weight: .heavy, design: .rounded)).monospacedDigit()
                if !state.next.isEmpty { Text(state.next).font(.caption2).lineLimit(1) }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.white)
            .activityBackgroundTint(.white)
            .activitySystemActionForegroundColor(.black)
        } else {
            HStack(spacing: 14) {
                Image(systemName: "timer").font(.title2).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.next.isEmpty ? "Timer" : "Recupero").font(.caption).foregroundStyle(.secondary)
                    if !state.next.isEmpty { Text(state.next).font(.subheadline.weight(.semibold)).lineLimit(1) }
                }
                Spacer(minLength: 8)
                countdown(state.end)
                    .font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                    .multilineTextAlignment(.trailing).frame(maxWidth: 110, alignment: .trailing)
            }
            .padding(16)
            .activityBackgroundTint(Color(.systemBackground))
        }
    }
}
