import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MoobilityCore

/// A fresh folder for each test, inside the system temp directory.
private final class TempFolder {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    var json: URL { url.appendingPathComponent("library.json") }
    func write(_ name: String, _ text: String = "x") {
        try! Data(text.utf8).write(to: url.appendingPathComponent(name))
    }
    func files() -> [String] { (try! FileManager.default.contentsOfDirectory(atPath: url.path)).sorted() }
}

private func store(_ folder: TempFolder) -> LibraryStore {
    let s = LibraryStore(folder: folder.url, trash: { try FileManager.default.removeItem(at: $0) })
    s.load()
    return s
}

private func md(_ m: Int, _ d: Int) -> MonthDay { MonthDay(month: m, day: d) }

private let allKinds: [TimingRule] = [
    .yearly(start: md(11, 1), end: md(11, 30)),
    .weekly(days: [6], window: .timed(start: 900, end: 1080)),
    .weekly(days: [2, 4], window: .allDay),
    .holiday(id: .diwali, leadDays: 3),
    .everyDay,
]

@Suite struct LibraryStoreTests {
    @Test func roundTrip() throws {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        s.setRules(allKinds, for: "a.jpg")
        let again = store(f)
        again.scan()
        #expect(again.photos.first?.rules == allKinds)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.json)) as! [String: Any]
        #expect(object["version"] as? Int == 1)
        let photo = (object["photos"] as! [[String: Any]])[0]
        #expect(photo["file"] as? String == "a.jpg")
        let rules = photo["rules"] as! [[String: Any]]
        #expect(rules[0]["kind"] as? String == "yearly")
        #expect(rules[0]["start"] as? String == "11-01")
        #expect(rules[1]["kind"] as? String == "weekly")
        #expect(rules[1]["days"] as? [Int] == [6])
        #expect(rules[1]["start"] as? String == "15:00")
        #expect(rules[1]["end"] as? String == "18:00")
        #expect(rules[2]["start"] == nil)
        #expect(rules[3]["holiday"] as? String == "diwali")
        #expect(rules[3]["leadDays"] as? Int == 3)
        #expect(rules[4]["kind"] as? String == "everyDay")
    }

    @Test func oddNamesRoundTrip() {
        let f = TempFolder()
        let name = "Día \"1\" 🎉.png"
        f.write(name)
        let s = store(f)
        s.scan()
        s.setRules([.everyDay], for: name)
        s.setTitle("Fiesta \"grande\" ñ", for: name)
        let again = store(f)
        again.scan()
        #expect(again.photos.first?.rules == [.everyDay])
        #expect(again.photos.first?.title == "Fiesta \"grande\" ñ")
    }

    private func expectPreserved(_ text: String) throws {
        let f = TempFolder()
        f.write("library.json", text)
        f.write("a.jpg")
        let s = store(f)
        #expect(s.problem == .timingUnreadable)
        #expect(s.problem?.message == "Couldn't read your timing; saved a copy")
        let copies = f.files().filter { $0.hasPrefix("library.json.bad-") }
        #expect(copies.count == 1)
        #expect(try String(contentsOf: f.url.appendingPathComponent(copies[0]), encoding: .utf8) == text)
        s.scan()
        s.setRules([.everyDay], for: "a.jpg")
        #expect(try String(contentsOf: f.url.appendingPathComponent(copies[0]), encoding: .utf8) == text)
        #expect(FileManager.default.fileExists(atPath: f.json.path))
    }

    @Test func corruptFileIsPreserved() throws { try expectPreserved("{ not json") }
    @Test func newerVersionIsPreserved() throws { try expectPreserved(#"{"version":2,"photos":[]}"#) }
    @Test func pathTraversalRejected() throws {
        try expectPreserved(#"{"version":1,"photos":[{"file":"../x.jpg","title":"x","rules":[]}]}"#)
    }
    @Test func unknownRuleRejected() throws {
        try expectPreserved(#"{"version":1,"photos":[{"file":"a.jpg","title":"x","rules":[{"kind":"lunar"}]}]}"#)
    }
    @Test func badDateRejected() throws {
        try expectPreserved(#"{"version":1,"photos":[{"file":"a.jpg","title":"x","rules":[{"kind":"yearly","start":"13-01","end":"13-02"}]}]}"#)
    }

    @Test func emptyFolderLoadsCleanly() {
        let f = TempFolder()
        let s = store(f)
        s.scan()
        #expect(s.photos.isEmpty)
        #expect(s.problem == nil)
    }

    @Test func scanFindsFinderAdditions() {
        let f = TempFolder()
        let s = store(f)
        s.scan()
        f.write("new.jpg")
        #expect(s.scan())
        #expect(s.photos.map(\.file) == ["new.jpg"])
        #expect(s.photos[0].rules.isEmpty)
        #expect(s.photos[0].title == "new")
        #expect(!s.scan())
    }

    @Test func scanSkipsNonPhotos() throws {
        let f = TempFolder()
        f.write("library.json", #"{"version":1,"photos":[]}"#)
        f.write("library.json.bad-123")
        f.write("notes.txt")
        f.write(".hidden.jpg")
        f.write("real.jpg")
        try FileManager.default.createDirectory(at: f.url.appendingPathComponent("sub.jpg"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.url.appendingPathComponent("link.jpg"),
                                                   withDestinationURL: f.url.appendingPathComponent("real.jpg"))
        let s = store(f)
        s.scan()
        #expect(s.photos.map(\.file) == ["real.jpg"])
    }

    @Test func deleteAndRestoreKeepsRules() throws {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        s.setRules([.everyDay], for: "a.jpg")
        try FileManager.default.removeItem(at: f.url.appendingPathComponent("a.jpg"))
        s.scan()
        #expect(s.photos.isEmpty)
        f.write("a.jpg")
        s.scan()
        #expect(s.photos.first?.rules == [.everyDay])
    }

    @Test func renameIsANewPhoto() throws {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        s.setRules([.everyDay], for: "a.jpg")
        try FileManager.default.moveItem(at: f.url.appendingPathComponent("a.jpg"), to: f.url.appendingPathComponent("b.jpg"))
        s.scan()
        #expect(s.photos.map(\.file) == ["b.jpg"])
        #expect(s.photos[0].rules.isEmpty)
        try FileManager.default.moveItem(at: f.url.appendingPathComponent("b.jpg"), to: f.url.appendingPathComponent("a.jpg"))
        s.scan()
        #expect(s.photos.first?.rules == [.everyDay])
    }

    @Test func normalizedNamesMatch() {
        let f = TempFolder()
        let nfc = "caf\u{e9}.png", nfd = "cafe\u{301}.png"
        f.write("library.json", #"{"version":1,"photos":[{"file":"\#(nfc)","title":"x","rules":[{"kind":"everyDay"}]}]}"#)
        f.write(nfd)
        let s = store(f)
        s.scan()
        #expect(s.photos.count == 1)
        #expect(s.photos.first?.rules == [.everyDay])
    }

    @Test func duplicateEntryLosesToFirst() {
        let f = TempFolder()
        f.write("library.json", #"{"version":1,"photos":[{"file":"a.jpg","title":"first","rules":[{"kind":"everyDay"}]},{"file":"a.jpg","title":"second","rules":[]}]}"#)
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        #expect(s.photos.map(\.title) == ["first"])
        #expect(s.problem == nil)
    }

    @Test func addClashAndAddFromInsideFolder() throws {
        let f = TempFolder(), source = TempFolder()
        source.write("photo.jpg", "one")
        let s = store(f)
        s.scan()
        let first = s.add([source.url.appendingPathComponent("photo.jpg")])
        let second = s.add([source.url.appendingPathComponent("photo.jpg")])
        #expect(first.map(\.file) == ["photo.jpg"])
        #expect(second.map(\.file) == ["photo 2.jpg"])
        #expect(s.photos.map(\.file) == ["photo.jpg", "photo 2.jpg"])
        #expect(s.add([f.url.appendingPathComponent("photo.jpg")]).isEmpty)
        #expect(f.files().filter { $0.hasSuffix(".jpg") }.count == 2)
        #expect(FileManager.default.fileExists(atPath: source.url.appendingPathComponent("photo.jpg").path))
    }

    @Test func addSkipsNonImages() {
        let f = TempFolder(), source = TempFolder()
        source.write("notes.txt")
        let s = store(f)
        s.scan()
        #expect(s.add([source.url.appendingPathComponent("notes.txt")]).isEmpty)
        #expect(!f.files().contains("notes.txt"))
    }

    @Test func removeTrashesAndForgets() {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        s.setRules([.everyDay], for: "a.jpg")
        s.remove("a.jpg")
        #expect(!f.files().contains("a.jpg"))
        #expect(s.photos.isEmpty)
        f.write("a.jpg")
        let again = store(f)
        again.scan()
        #expect(again.photos.first?.rules == [])
    }

    @Test func moveChangesOrderAndPersists() {
        let f = TempFolder()
        for n in ["a.jpg", "b.jpg", "c.jpg"] { f.write(n) }
        let s = store(f)
        s.scan()
        let names = s.photos.map(\.file)
        s.move(file: names[2], toIndex: 0)
        #expect(s.photos.map(\.file) == [names[2], names[0], names[1]])
        let again = store(f)
        again.scan()
        #expect(again.photos.map(\.file) == [names[2], names[0], names[1]])
    }

    @Test func fingerprintChangesOnReplace() throws {
        let f = TempFolder()
        f.write("a.jpg", "same")
        let s = store(f)
        s.scan()
        let before = try #require(s.fingerprint(of: "a.jpg"))
        let date = try FileManager.default.attributesOfItem(atPath: f.url.appendingPathComponent("a.jpg").path)[.modificationDate]
        try Data("diff".utf8).write(to: f.url.appendingPathComponent("a.jpg"), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: f.url.appendingPathComponent("a.jpg").path)
        #expect(s.scan())
        #expect(s.fingerprint(of: "a.jpg") != before)
    }

    @Test func folderDeletedWhileRunning() throws {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        try FileManager.default.removeItem(at: f.url)
        s.scan()
        #expect(FileManager.default.fileExists(atPath: f.url.path))
        #expect(s.photos.isEmpty)
        #expect(s.problem == nil)
    }

    /// Final review: scan() never re-read the file, so a restored or seeded file was overwritten by the next save.
    @Test func externalEditIsPickedUp() throws {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        try Data(#"{"version":1,"photos":[{"file":"a.jpg","title":"Edited","rules":[{"kind":"everyDay"}]}]}"#.utf8)
            .write(to: f.json, options: .atomic)
        #expect(s.scan())
        #expect(s.photos.first?.title == "Edited")
        #expect(s.photos.first?.rules == [.everyDay])
    }

    @Test func repairedFileClearsTheWarning() throws {
        let f = TempFolder()
        f.write("library.json", "{ broken")
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        #expect(s.problem == .timingUnreadable)
        try Data(#"{"version":1,"photos":[{"file":"a.jpg","title":"a","rules":[{"kind":"everyDay"}]}]}"#.utf8)
            .write(to: f.json, options: .atomic)
        s.scan()
        #expect(s.problem == nil)
        #expect(s.photos.first?.rules == [.everyDay])
    }

    @Test func seedingWhileRunningKeepsItsRules() throws {
        let f = TempFolder()
        let s = store(f)
        s.scan()
        f.write("a.jpg")
        s.scan()           // saves a rule-less entry, as a running app would
        try Data(#"{"version":1,"photos":[{"file":"a.jpg","title":"Seeded","rules":[{"kind":"everyDay"}]}]}"#.utf8)
            .write(to: f.json, options: .atomic)
        s.scan()
        s.setTitle("Later edit", for: "a.jpg")
        let again = store(f)
        again.scan()
        #expect(again.photos.first?.rules == [.everyDay])
        #expect(again.photos.first?.title == "Later edit")
    }

    @Test func ownSaveIsNotAnExternalEdit() {
        let f = TempFolder()
        f.write("a.jpg")
        let s = store(f)
        s.scan()
        s.setRules([.everyDay], for: "a.jpg")
        #expect(!s.scan())
    }

    /// Final review: a failed copy was reported, then cleared by the save of the photos that did copy.
    @Test func failedCopyIsReportedUntilAnAddSucceeds() throws {
        let f = TempFolder(), source = TempFolder()
        source.write("good.jpg")
        source.write("locked.jpg")
        let locked = source.url.appendingPathComponent("locked.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let s = store(f)
        s.scan()
        let added = s.add([locked, source.url.appendingPathComponent("good.jpg")])
        #expect(added.map(\.file) == ["good.jpg"])
        #expect(s.problem == .cannotAddPhoto)
        #expect(s.problem?.message == "Couldn't add some photos")
        source.write("next.jpg")
        _ = s.add([source.url.appendingPathComponent("next.jpg")])
        #expect(s.problem == nil)
    }
}
