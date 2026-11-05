import Foundation
import Testing
@testable import MoobilityCore

/// Runs a script from scripts/ and returns what it printed. Release scripts are the only thing between a tag and users.
func runScript(_ name: String, _ arguments: [String] = [], in folder: URL? = nil, environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = Fixture.repoRoot.appendingPathComponent("scripts/\(name)")
    process.arguments = arguments
    if let folder { process.currentDirectoryURL = folder }
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@discardableResult
func git(_ arguments: [String], in folder: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
    process.currentDirectoryURL = folder
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@Suite struct VersionNumberTests {
    private func build(_ tag: String) throws -> Int {
        let result = try runScript("version-numbers.sh", [tag])
        #expect(result.status == 0)
        let line = result.output.split(separator: "\n").first { $0.hasPrefix("CURRENT_PROJECT_VERSION=") }
        return Int(line?.split(separator: "=").last ?? "") ?? -1
    }

    @Test func versionNumbers() throws {
        let tagged = try runScript("version-numbers.sh", ["v1.2.3"])
        #expect(tagged.output == "MARKETING_VERSION=1.2.3\nCURRENT_PROJECT_VERSION=1002003\n")
        let bare = try runScript("version-numbers.sh", ["1.2.3"])
        #expect(bare.output == tagged.output)
    }

    @Test func laterVersionsHaveHigherBuilds() throws {
        #expect(try build("v1.10.0") > build("v1.9.9"))
        #expect(try build("v2.0.0") > build("v1.999.999"))
    }

    @Test func badVersionsFail() throws {
        // An enormous component wraps around in shell arithmetic, and leading zeros would let two versions share a build.
        for bad in ["v1.1000.0", "v1.0.1000", "v1.2", "1.2.3-rc1", "abc", "", "v1.2.3.4", "v-1.2.3",
                    "v1.18446744073709551616.0", "v99999999999999999999.0.0", "v1.02.3", "v01.2.3", "v1.2.03"] {
            let result = try runScript("version-numbers.sh", [bad])
            #expect(result.status != 0, "\(bad)")
            #expect(result.output.isEmpty, "\(bad)")
        }
    }
}

/// `check-extension-version.sh <last tag>` fails when Extension/ changed and EXTENSION_BUILD didn't.
@Suite struct ExtensionVersionCheckTests {
    private func repo() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("extcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Extension"), withIntermediateDirectories: true)
        try git(["init", "-q"], in: folder)
        try write("code", to: "Extension/a.swift", in: folder)
        try write("    EXTENSION_BUILD: \"5\"\n", to: "project.yml", in: folder)
        try git(["add", "-A"], in: folder)
        try git(["commit", "-qm", "one"], in: folder)
        try git(["tag", "v1.0.0"], in: folder)
        return folder
    }

    private func write(_ text: String, to path: String, in folder: URL) throws {
        try text.write(to: folder.appendingPathComponent(path), atomically: false, encoding: .utf8)
    }

    private func commit(_ folder: URL) throws {
        try git(["add", "-A"], in: folder)
        try git(["commit", "-qm", "two"], in: folder)
    }

    @Test func extensionChangeWithoutBumpFails() throws {
        let folder = try repo()
        try write("changed", to: "Extension/a.swift", in: folder)
        try commit(folder)
        #expect(try runScript("check-extension-version.sh", ["v1.0.0"], in: folder).status != 0)
    }

    @Test func extensionChangeWithBumpPasses() throws {
        let folder = try repo()
        try write("changed", to: "Extension/a.swift", in: folder)
        try write("    EXTENSION_BUILD: \"6\"\n", to: "project.yml", in: folder)
        try commit(folder)
        #expect(try runScript("check-extension-version.sh", ["v1.0.0"], in: folder).status == 0)
    }

    @Test func appOnlyChangePasses() throws {
        let folder = try repo()
        try write("notes", to: "README.md", in: folder)
        try commit(folder)
        #expect(try runScript("check-extension-version.sh", ["v1.0.0"], in: folder).status == 0)
    }

    @Test func noPreviousTagPasses() throws {
        let folder = try repo()
        #expect(try runScript("check-extension-version.sh", [""], in: folder).status == 0)
    }
}

@Suite struct VerifyReleaseTests {
    @Test func verifyRefusesAnUnsignedApp() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let result = try runScript("verify-release.sh", [app.path])
        #expect(result.status != 0)
        #expect(result.output.contains("VERIFY FAILED"))
    }
}

@Suite struct PublicTreeCheckTests {
    private func repo(_ files: [String: String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("public-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git(["init", "-q"], in: folder)
        for (path, text) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: false, encoding: .utf8)
        }
        try git(["add", "-A"], in: folder)
        try git(["commit", "-qm", "files"], in: folder)
        return folder
    }

    private func status(_ files: [String: String]) throws -> Int32 {
        try runScript("check-public-tree.sh", [], in: repo(files)).status
    }

    @Test func publicCheckPassesCleanTree() throws {
        #expect(try status(["App/a.swift": "code", "raw/seasons/spring.png": "x", "raw/cows/office.png": "x"]) == 0)
    }

    @Test func publicCheckFailsOnLeftOutPath() throws {
        for path in ["final/default.png", "raw/base.png", "schedule.json", "docs/superpowers/specs/x.md",
                     "scripts/moobility-library.json", "scripts/export-public-tree.sh"] {
            #expect(try status(["App/a.swift": "code", path: "x"]) != 0, "\(path)")
        }
    }

    @Test func publicCheckFailsOnPersonalPath() throws {
        let personal = "/Users/" + "alex" + "/sites/x"   // built up, so this file doesn't trip the check itself
        #expect(try status(["App/a.swift": "let p = \"\(personal)\""]) != 0)
        #expect(try status(["App/a.swift": "let p = \"/Users/someone/sites/x\""]) == 0)
    }
}

/// Checks an update the way an installed copy will: the feed's signature, against the app's public key.
@Suite struct UpdateSignatureTests {
    private let openssl = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/opt/openssl@3/bin/openssl")
        ? "/opt/homebrew/opt/openssl@3/bin/openssl" : "/usr/bin/env"

    private func run(_ arguments: [String], in folder: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = (openssl.hasSuffix("env") ? ["openssl"] : []) + arguments
        process.currentDirectoryURL = folder
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// A folder with a fake app holding `appKey`'s public key, a zip, and a feed signed by `signKey`.
    private func fixture(appKey: String, signKey: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("My.app/Contents"), withIntermediateDirectories: true)
        for key in Set([appKey, signKey]) {
            _ = try run(["genpkey", "-algorithm", "ed25519", "-out", key], in: folder)
        }
        let der = try run(["pkey", "-in", appKey, "-pubout", "-outform", "DER"], in: folder)
        let publicKey = der.suffix(32).base64EncodedString()
        try """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>SUPublicEDKey</key><string>\(publicKey)</string></dict></plist>
        """.write(to: folder.appendingPathComponent("My.app/Contents/Info.plist"), atomically: false, encoding: .utf8)
        try "update bytes".write(to: folder.appendingPathComponent("update.zip"), atomically: false, encoding: .utf8)
        let signature = try run(["pkeyutl", "-sign", "-inkey", signKey, "-rawin", "-in", "update.zip"], in: folder).base64EncodedString()
        try """
        <rss><channel><item><enclosure url="https://example.com/update.zip" sparkle:edSignature="\(signature)" length="12"/></item></channel></rss>
        """.write(to: folder.appendingPathComponent("appcast.xml"), atomically: false, encoding: .utf8)
        return folder
    }

    private func verify(_ folder: URL) throws -> Int32 {
        try runScript("verify-update-signature.sh", ["My.app", "update.zip", "appcast.xml"], in: folder).status
    }

    @Test func matchingKeyPasses() throws {
        #expect(try verify(fixture(appKey: "a.txt", signKey: "a.txt")) == 0)
    }

    @Test func aDifferentSigningKeyFails() throws {
        #expect(try verify(fixture(appKey: "a.txt", signKey: "b.txt")) != 0)
    }

    @Test func aChangedZipFails() throws {
        let folder = try fixture(appKey: "a.txt", signKey: "a.txt")
        try "other bytes!".write(to: folder.appendingPathComponent("update.zip"), atomically: false, encoding: .utf8)
        #expect(try verify(folder) != 0)
    }
}
