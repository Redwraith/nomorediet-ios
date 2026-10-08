import ActivityKit
import Foundation

/// Starts, updates and ends the rest-timer Live Activity.
enum LiveTimer {
    static func start(end: Date, next: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: RestTimerAttributes.ContentState(end: end, next: next),
                                      staleDate: end.addingTimeInterval(60))
        if let current = Activity<RestTimerAttributes>.activities.first {
            Task { await current.update(content) }
        } else {
            _ = try? Activity.request(attributes: RestTimerAttributes(title: "Recupero"), content: content, pushType: nil)
        }
    }

    static func stop() {
        for activity in Activity<RestTimerAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
