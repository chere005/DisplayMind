import AppKit
import Combine

struct ReleaseUpdate {
	let version: String
	let downloadURL: URL

	private struct Release: Decodable {
		struct Asset: Decodable {
			let name: String
			let state: String
			let browserDownloadUrl: URL
		}
		let tagName: String
		let draft: Bool
		let prerelease: Bool
		let assets: [Asset]
	}

	static let repository = "chere005/DisplayMind"

	static func available(in data: Data, installedVersion: String) throws -> ReleaseUpdate? {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		let release = try decoder.decode(Release.self, from: data)
		guard !release.draft, !release.prerelease, release.tagName.hasPrefix("v") else { return nil }
		let version = String(release.tagName.dropFirst())
		guard let current = components(of: installedVersion), let latest = components(of: version),
		      current.lexicographicallyPrecedes(latest) else { return nil }
		let name = "DisplayMind-\(version).dmg"
		let url = URL(string: "https://github.com/\(repository)/releases/download/\(release.tagName)/\(name)")!
		guard release.assets.contains(where: { $0.name == name && $0.state == "uploaded" && $0.browserDownloadUrl == url }) else { return nil }
		return ReleaseUpdate(version: version, downloadURL: url)
	}

	private static func components(of version: String) -> [Int]? {
		let parts = version.split(separator: ".", omittingEmptySubsequences: false)
		let numbers = parts.compactMap { part -> Int? in
			guard let number = Int(part), number >= 0, String(number) == part else { return nil }
			return number
		}
		return parts.count == 3 && numbers.count == 3 ? numbers : nil
	}
}

@MainActor final class UpdateChecker: ObservableObject {
	@Published private(set) var available: ReleaseUpdate?
	@Published private(set) var checking = false
	private let notifiedVersionKey = "lastNotifiedUpdateVersion"
	private var timer: Timer?

	func start() {
		Task { await check() }
		let interval: TimeInterval = 24 * 60 * 60
		timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
			Task { @MainActor in await self?.check() }
		}
		timer?.tolerance = 60 * 60
	}

	deinit { timer?.invalidate() }

	func check(manual: Bool = false) async {
		guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
		guard !checking else { return }
		checking = true
		defer { checking = false }

		do {
			let data = try await Self.latestRelease()
			available = try ReleaseUpdate.available(in: data, installedVersion: version)
			if let update = available {
				let defaults = UserDefaults.standard
				let alreadyNotified = defaults.string(forKey: notifiedVersionKey) == update.version
				if manual { present(update) }
				else if !alreadyNotified {
					Notifier.live.post("DisplayMind \(update.version) is available", "Open the DisplayMind menu to download the installer.")
				}
				defaults.set(update.version, forKey: notifiedVersionKey)
			} else if manual {
				present(title: "No newer installer available", message: "You’re running DisplayMind \(version).")
			}
		} catch {
			if manual { present(title: "Couldn’t check for updates", message: "DisplayMind couldn’t read the latest release from GitHub.") }
		}
	}

	private func present(_ update: ReleaseUpdate) {
		present(title: "DisplayMind \(update.version) is available",
		        message: "Download the disk image, then drag DisplayMind to Applications to install it.", download: update.downloadURL)
	}

	private func present(title: String, message: String, download: URL? = nil) {
		let alert = NSAlert()
		alert.messageText = title
		alert.informativeText = message
		if download != nil { alert.addButton(withTitle: "Download Update") }
		alert.addButton(withTitle: download == nil ? "OK" : "Later")
		NSApplication.shared.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertFirstButtonReturn, let download { NSWorkspace.shared.open(download) }
	}

	private nonisolated static func latestRelease() async throws -> Data {
		let endpoint = "repos/\(ReleaseUpdate.repository)/releases/latest"
		var request = URLRequest(url: URL(string: "https://api.github.com/\(endpoint)")!,
		                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
		request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		let (data, response) = try await URLSession.shared.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode
		if status == 200 { return data }

		// Private releases return 404 unless authenticated. Reuse a local GitHub CLI login when available.
		guard status == 404, let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile) else {
			throw URLError(.badServerResponse)
		}
		let arguments = ["GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "DO_NOT_TRACK=1", gh, "api", "--hostname", "github.com", endpoint]
		return try await Task.detached(priority: .utility) {
			let output = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments, timeout: 15)
			return Data(output.utf8)
		}.value
	}
}
