import Foundation
import UIKit
import UserNotifications

/// Over-the-air updates of the app itself. Every build published by CI goes to the public
/// `nomorediet-updates` repository as a SideStore/AltStore source (apps.json). The app reads that file,
/// and when a newer build exists shows a banner; SideStore downloads and installs it with one tap
/// (iOS does not allow a sideloaded app to replace itself).
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/Redwraith/nomorediet-updates/main/apps.json")!

    struct Release: Equatable {
        let version: String
        let build: Int
        let notes: String
    }

    @Published private(set) var available: Release?
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: "update.lastCheck") as? Date
    @Published var dismissedBuild = UserDefaults.standard.integer(forKey: "update.dismissed") {
        didSet { UserDefaults.standard.set(dismissedBuild, forKey: "update.dismissed") }
    }

    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// The banner shows a new build until the user hides it.
    var showBanner: Bool { (available?.build ?? 0) > dismissedBuild }

    /// Checks at most every 6 hours unless forced.
    func checkIfNeeded(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "update.lastCheck")
            available = Self.newest(in: data, newerThan: Self.currentBuild)
            if let available { notifyOnce(available) }
        } catch {
            DebugLog.shared.add("info", "update", "Controllo aggiornamenti non riuscito: \(error.localizedDescription)")
        }
    }

    /// The newest release in a SideStore source that is newer than `build`, or nil.
    nonisolated static func newest(in data: Data, newerThan build: Int) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = (json["apps"] as? [[String: Any]])?.first(where: { $0["bundleIdentifier"] as? String == "app.piatto.ios" }),
              let versions = app["versions"] as? [[String: Any]] else { return nil }
        let releases = versions.compactMap { v -> Release? in
            guard let version = v["version"] as? String,
                  let b = Int(v["buildVersion"] as? String ?? "") else { return nil }
            return Release(version: version, build: b, notes: v["localizedDescription"] as? String ?? "")
        }
        return releases.max { $0.build < $1.build }.flatMap { $0.build > build ? $0 : nil }
    }

    static let releasesPage = URL(string: "https://github.com/Redwraith/nomorediet-updates/releases/latest")!

    /// Opens SideStore/AltStore on the update (adds the source the first time). Without them (Sideloadly)
    /// opens the download page: the .ipa is then installed from the computer.
    func openSideStore() {
        let source = Self.sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let links = ["sidestore://source?url=\(source)", "altstore://source?url=\(source)", "sidestore://", "altstore://"]
        Task {
            for link in links {
                if let url = URL(string: link), await UIApplication.shared.open(url) { return }
            }
            await UIApplication.shared.open(Self.releasesPage)
        }
    }

    private func notifyOnce(_ release: Release) {
        let key = "update.notified"
        guard UserDefaults.standard.integer(forKey: key) < release.build else { return }
        UserDefaults.standard.set(release.build, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "Nomorediet \(release.version) disponibile"
        content.body = "Tocca Aggiorna nell'app per installarla."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(release.build)", content: content, trigger: nil))
    }
}
