import XCTest
@testable import DisplayMind

final class UpdateCheckerTests: XCTestCase {
	private func release(tag: String = "v0.20.0", filename: String? = "DisplayMind-0.20.0.dmg",
	                     downloadURL: String? = nil, state: String = "uploaded",
	                     draft: Bool = false, prerelease: Bool = false) throws -> Data {
		let assets = filename.map { name in
			[["name": name, "state": state, "browser_download_url": downloadURL ?? "https://github.com/chere005/DisplayMind/releases/download/\(tag)/\(name)"]]
		} ?? []
		return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets])
	}

	func testNumericVersionOrderingAndTrustedDownload() throws {
		let data = try release()
		let update = try XCTUnwrap(ReleaseUpdate.available(in: data, installedVersion: "0.9.0"))
		XCTAssertEqual(update.version, "0.20.0")
		XCTAssertEqual(update.downloadURL.absoluteString, "https://github.com/chere005/DisplayMind/releases/download/v0.20.0/DisplayMind-0.20.0.dmg")
		XCTAssertNil(try ReleaseUpdate.available(in: data, installedVersion: "0.20.0"))
		XCTAssertNil(try ReleaseUpdate.available(in: data, installedVersion: "0.21.0"))
	}

	func testOnlyPublishedReleasesWithUploadedInstallersQualify() throws {
		for data in try [release(filename: nil), release(filename: "DisplayMind-0.20.0-unnotarized.dmg"),
		                 release(state: "new"), release(draft: true), release(prerelease: true),
		                 release(tag: "v0.20.0-beta"), release(tag: "v0.020.0")] {
			XCTAssertNil(try ReleaseUpdate.available(in: data, installedVersion: "0.19.0"))
		}
	}

	func testRejectsAnInstallerOutsideTheExpectedRepositoryAndTag() throws {
		for url in ["https://downloads.example/DisplayMind-0.20.0.dmg",
		            "https://github.com/another/DisplayMind/releases/download/v0.20.0/DisplayMind-0.20.0.dmg",
		            "https://github.com/chere005/DisplayMind/releases/download/v0.21.0/DisplayMind-0.20.0.dmg"] {
			XCTAssertNil(try ReleaseUpdate.available(in: release(downloadURL: url), installedVersion: "0.19.0"))
		}
	}
}
