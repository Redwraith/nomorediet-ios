import ActivityKit
import Foundation

/// Live Activity for the rest timer between jump-set exercises (lock screen + Dynamic Island).
struct RestTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var end: Date
        var next: String
    }
    var title: String
}
