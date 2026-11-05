import Foundation
import Testing
@testable import MoobilityCore

/// The app and the extension can't share code, so values that must agree are checked here.
@Suite struct IdentityConsistencyTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Fixture.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func firstMatch(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        let match = try #require(regex.firstMatch(in: text, range: range), "no match for \(pattern)")
        return String(text[try #require(Range(match.range(at: 1), in: text))])
    }

    private func projectBundleIDs() throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"PRODUCT_BUNDLE_IDENTIFIER: (\S+)"#)
        let text = try source("project.yml")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    @Test func deviceUIDMatches() throws {
        let inExtension = try firstMatch(#"deviceUID = UUID\(uuidString: "([^"]+)""#, in: source("Extension/Constants.swift"))
        let inApp = try firstMatch(#"deviceUID = "([^"]+)""#, in: source("App/CMIOLookup.swift"))
        #expect(inExtension == inApp)
    }

    @Test func clientCountSelectorMatches() throws {
        let inExtension = try firstMatch(#"4cc_([a-z]{4})_glob_0000"#, in: source("Extension/Constants.swift"))
        let hex = try firstMatch(#"clientCountSelector: CMIOObjectPropertySelector = 0x([0-9A-Fa-f_]+)"#, in: source("App/CMIOLookup.swift"))
        let value = try #require(UInt32(hex.replacingOccurrences(of: "_", with: ""), radix: 16))
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        #expect(String(decoding: bytes, as: UTF8.self) == inExtension)
    }

    @Test func extensionIDMatches() throws {
        let installer = try firstMatch(#"extensionID = "([^"]+)""#, in: source("App/ExtensionInstaller.swift"))
        #expect(try projectBundleIDs().contains(installer))
        let plist = try source("Extension/Info.plist")
        #expect(plist.contains("$(TeamIdentifierPrefix)\(installer)</string>"))
    }

    @Test func clientCheckNamesTheInstalledPath() throws {
        let path = try firstMatch(#"installedExecutable = "([^"]+)""#, in: source("Extension/ClientCheck.swift"))
        let name = try firstMatch(#"PRODUCT_NAME: (\S+)"#, in: source("project.yml"))
        #expect(path == "/Applications/\(name).app/Contents/MacOS/\(name)")
        let appModel = try firstMatch(#"installedApp = URL\(fileURLWithPath: "([^"]+)""#, in: source("App/AppModel.swift"))
        #expect(path.hasPrefix(appModel + "/"))
    }

    /// macOS treats either version changing as a new extension, and replacing a running one can need a restart.
    /// So the extension's versions must not follow the app's.
    @Test func extensionVersionsDontFollowTheApp() throws {
        let project = try source("project.yml")
        let extensionPart = try #require(project.range(of: "MoobilityCamExtension:\n    type:", options: .regularExpression))
        let properties = String(project[extensionPart.lowerBound...])
        #expect(properties.contains("CFBundleShortVersionString: $(EXTENSION_VERSION)"))
        #expect(properties.contains("CFBundleVersion: $(EXTENSION_BUILD)"))
    }

    @Test func clientCheckNamesTheApp() throws {
        let appID = try firstMatch(#"appBundleID = "([^"]+)""#, in: source("Extension/ClientCheck.swift"))
        #expect(try projectBundleIDs().contains(appID))
        #expect(!appID.hasSuffix(".Extension"))
    }
}
