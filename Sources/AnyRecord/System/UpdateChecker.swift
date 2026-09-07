import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and can install it in place.
///
/// Release flow: `scripts/release.sh 0.2.0` bumps the version, tags `v0.2.0`,
/// builds the app, zips it and publishes a GitHub release with the zip attached.
/// The app compares its `CFBundleShortVersionString` with the latest release tag.
/// Uses the unauthenticated GitHub API, so it works for every user once the
/// repository is public. While the repository is private the check reports
/// that no release is reachable.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "moritzjkr/AnyRecord"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(version: String, notes: String, assetURL: URL, assetName: String)
        case downloading(Double)
        case failed(String)
    }

    @Published var status: Status = .idle
    @Published var lastCheck: Date? = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    static var buildInfo: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let hash = Bundle.main.infoDictionary?["AnyRecordGitHash"] as? String ?? ""
        return hash.isEmpty ? "build \(build)" : "build \(build), \(hash)"
    }

    // MARK: - Check

    /// Checks at most once a day when called automatically.
    func checkAutomaticallyIfDue() async {
        guard AppSettings.shared.autoCheckUpdates else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(interactive: false)
    }

    func check(interactive: Bool) async {
        status = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(UpdateChecker.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
            if http.statusCode == 404 {
                throw UpdateError.message("No release reachable. The repository may still be private.")
            }
            guard http.statusCode == 200 else { throw UpdateError.message("GitHub answered \(http.statusCode).") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")

            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard UpdateChecker.isNewer(latest, than: UpdateChecker.currentVersion) else {
                status = .upToDate(latest)
                if interactive { notify("AnyRecord is up to date", "Version \(UpdateChecker.currentVersion) is the latest release.") }
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                throw UpdateError.message("Release \(latest) has no .zip attached.")
            }
            status = .available(version: latest, notes: release.body ?? "", assetURL: URL(string: asset.url)!, assetName: asset.name)
            if interactive || AppSettings.shared.autoCheckUpdates { offerInstall(version: latest, notes: release.body ?? "") }
        } catch {
            status = .failed(error.localizedDescription)
            if interactive { notify("Update check failed", error.localizedDescription) }
        }
    }

    private func offerInstall(version: String, notes: String) {
        let alert = NSAlert()
        alert.messageText = "AnyRecord \(version) is available"
        alert.informativeText = "You have \(UpdateChecker.currentVersion).\n\n" + (notes.isEmpty ? "" : String(notes.prefix(600)))
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await installAvailableUpdate() }
        }
    }

    // MARK: - Install

    func installAvailableUpdate() async {
        guard case .available(_, _, let assetURL, _) = status else { return }
        guard !AppState.shared.isRecording else {
            notify("Recording in progress", "Stop the recording before installing an update.")
            return
        }
        status = .downloading(0)
        do {
            var request = URLRequest(url: assetURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (tmp, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed.") }

            let work = FileManager.default.temporaryDirectory.appendingPathComponent("AnyRecordUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            try run("/usr/bin/ditto", ["-xk", zip.path, work.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.message("The archive contains no .app.") }

            let current = Bundle.main.bundleURL
            guard current.pathExtension == "app" else { throw UpdateError.message("Not running from an .app bundle – use scripts/bundle.sh instead.") }
            // Swap: move the running app aside (it keeps running from the old inode), put the new one in place.
            let backup = work.appendingPathComponent("previous.app")
            try FileManager.default.moveItem(at: current, to: backup)
            try FileManager.default.moveItem(at: newApp, to: current)
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", current.path])
            AppLog.write("Installed update from \(assetURL.lastPathComponent); relaunching")

            // Relaunch the new copy after this process exits.
            let script = "sleep 1; open \"\(current.path)\""
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", script]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
            notify("Update failed", error.localizedDescription)
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.message("\(tool) failed (\(p.terminationStatus)).") }
    }

    private func notify(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Helpers

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let url: String }
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case message(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Unexpected response from GitHub."
            case .message(let m): return m
            }
        }
    }
}
