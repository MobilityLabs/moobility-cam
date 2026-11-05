import Foundation
import Testing
@testable import MoobilityCore

private final class TrashLog: @unchecked Sendable {
    var urls: [URL] = []
}

@Suite struct ClipStoreTests {
    private let root: URL
    private let log = TrashLog()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)")
    }

    private var store: ClipStore {
        let log = self.log
        return ClipStore(folder: root, trash: { url in
            log.urls.append(url)
            try FileManager.default.removeItem(at: url)
        })
    }

    private func write(_ name: String, modified: Date? = nil, contents: String = "x") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: false, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func files() -> [String] {
        store.list().map(\.file)
    }

    @Test func missingFolderListsEmpty() {
        #expect(store.list().isEmpty)
    }

    @Test func firstPartURLCreatesFolder() throws {
        let part = try store.newPartURL(base: "Recording")
        #expect(part.lastPathComponent.hasPrefix("Recording"))
        #expect(part.pathExtension == "part")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func partURLsAreUniqueBeforeAnyFileExists() throws {
        let first = try store.newPartURL(base: "a")
        let second = try store.newPartURL(base: "a")
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func listIsMovOnlyNewestFirst() throws {
        try write("old.mov", modified: Date(timeIntervalSince1970: 1000))
        try write("new.mov", modified: Date(timeIntervalSince1970: 3000))
        try write("middle.mov", modified: Date(timeIntervalSince1970: 2000))
        try write("x.mov.part")
        try write("photo.jpg")
        try write(".hidden.mov")
        #expect(files() == ["new.mov", "middle.mov", "old.mov"])
        #expect(store.list().first?.title == "new")
    }

    @Test func defaultBaseFormat() {
        let date = Fixture.date(2026, 11, 4, 14, 3)
        let base = ClipStore.defaultBase("Recording", at: date, timeZone: TimeZone(identifier: "America/New_York")!)
        #expect(base == "Recording 2026-11-04 14.03")
    }

    @Test func publishMovesPart() throws {
        let part = try store.newPartURL(base: "a")
        try "movie".write(to: part, atomically: false, encoding: .utf8)
        #expect(try store.publish(part: part, base: "a") == "a.mov")
        #expect(!FileManager.default.fileExists(atPath: part.path))
        #expect(files() == ["a.mov"])
    }

    @Test func publishCollisionAddsSuffix() throws {
        try write("a.mov", contents: "first")
        let part = try store.newPartURL(base: "a")
        try "second".write(to: part, atomically: false, encoding: .utf8)
        #expect(try store.publish(part: part, base: "a") == "a 2.mov")
        let another = try store.newPartURL(base: "a")
        try "third".write(to: another, atomically: false, encoding: .utf8)
        #expect(try store.publish(part: another, base: "a") == "a 3.mov")
        #expect(try String(contentsOf: root.appendingPathComponent("a.mov"), encoding: .utf8) == "first")
    }

    @Test func publishCollisionIgnoresCase() throws {
        try write("A.mov")
        let part = try store.newPartURL(base: "a")
        try "x".write(to: part, atomically: false, encoding: .utf8)
        #expect(try store.publish(part: part, base: "a") == "a 2.mov")
    }

    @Test func renameRules() throws {
        try write("one.mov")
        try write("two.mov")
        for bad in ["", "   ", "a/b", "a:b", ".a"] {
            #expect(throws: ClipNameError.invalid) { try store.rename("one.mov", to: bad) }
        }
        #expect(throws: ClipNameError.taken) { try store.rename("one.mov", to: "TWO") }
        #expect(Set(files()) == ["one.mov", "two.mov"])
        #expect(try store.rename("one.mov", to: "three") == "three.mov")
        #expect(Set(files()) == ["three.mov", "two.mov"])
    }

    @Test func caseOnlyRenameOfSelf() throws {
        try write("abc.mov")
        #expect(try store.rename("abc.mov", to: "ABC") == "ABC.mov")
        #expect(files() == ["ABC.mov"])
    }

    @Test func unicodeNames() throws {
        try write("CAFÉ.mov")
        try write("other.mov")
        #expect(throws: ClipNameError.taken) { try store.rename("other.mov", to: "cafe\u{301}") }
        #expect(try store.rename("other.mov", to: "Résumé ✨") == "Résumé ✨.mov")
    }

    @Test func deleteUsesTrash() throws {
        try write("a.mov")
        try store.delete("a.mov")
        #expect(log.urls.map(\.lastPathComponent) == ["a.mov"])
        #expect(files().isEmpty)
    }

    @Test func removeLeftoverPartsOnlyTouchesParts() throws {
        try write("a.mov")
        try write("b.mov.part")
        store.removeLeftoverParts()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.mov").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.mov.part").path))
    }

    @Test func targetAfterRemovingAndRenaming() {
        let clip = ReplayTarget.clip(file: "a.mov")
        #expect(clip.afterRemoving(file: "a.mov") == .default)
        #expect(clip.afterRemoving(file: "b.mov") == clip)
        #expect(ReplayTarget.last(seconds: 30).afterRemoving(file: "a.mov") == .last(seconds: 30))
        #expect(clip.afterRenaming("a.mov", to: "c.mov") == .clip(file: "c.mov"))
        #expect(clip.afterRenaming("b.mov", to: "c.mov") == clip)
    }

    @Test func clipTimeText() {
        #expect(ClipTime.text(0) == "0:00")
        #expect(ClipTime.text(9.6) == "0:10")
        #expect(ClipTime.text(61) == "1:01")
        #expect(ClipTime.text(300) == "5:00")
        #expect(ClipTime.text(.nan) == "")
        #expect(ClipTime.text(.infinity) == "")
        #expect(ClipTime.text(-1) == "")
        #expect(ClipTime.text(1e30) == "")
        #expect(ClipTime.text(nil) == "")
    }

    @Test func hotKeyRules() {
        let shift: UInt32 = 512, cmd: UInt32 = 256, opt: UInt32 = 2048, ctrl: UInt32 = 4096
        #expect(HotKeyCombo(keyCode: 15, carbonModifiers: 0) == nil)
        #expect(HotKeyCombo(keyCode: 15, carbonModifiers: shift) == nil)
        #expect(HotKeyCombo(keyCode: 15, carbonModifiers: cmd) != nil)
        #expect(HotKeyCombo(keyCode: 15, carbonModifiers: opt | shift) != nil)
        #expect(HotKeyCombo.default.keyCode == 15)
        #expect(HotKeyCombo.default.carbonModifiers == cmd | opt | ctrl)
        #expect(HotKeyCombo.default.stored == "15:6400")
        #expect(HotKeyCombo(stored: "15:6400") == .default)
        for bad in ["15", "x:y", "15:512", ""] {
            #expect(HotKeyCombo(stored: bad) == nil)
        }
        #expect(HotKeyCombo.default.display == "⌃⌥⌘R")
        #expect(HotKeyCombo(keyCode: 122, carbonModifiers: cmd)?.display == "⌘F1")
        #expect(HotKeyCombo(keyCode: 200, carbonModifiers: shift | cmd)?.display == "⇧⌘Key 200")
    }

    @Test func singleInstance() {
        let now = Date(timeIntervalSince1970: 1000)
        let me = SingleInstance.Running(pid: 50, launched: now)
        #expect(!SingleInstance.shouldQuit(me: me, others: []))
        #expect(SingleInstance.shouldQuit(me: me, others: [.init(pid: 60, launched: now.addingTimeInterval(-5))]))
        #expect(!SingleInstance.shouldQuit(me: me, others: [.init(pid: 40, launched: now.addingTimeInterval(5))]))
        #expect(SingleInstance.shouldQuit(me: me, others: [.init(pid: 40, launched: now)]))
        #expect(!SingleInstance.shouldQuit(me: me, others: [.init(pid: 60, launched: now)]))
        let noDate = SingleInstance.Running(pid: 50, launched: nil)
        #expect(SingleInstance.shouldQuit(me: noDate, others: [.init(pid: 40, launched: nil)]))
        #expect(!SingleInstance.shouldQuit(me: noDate, others: [.init(pid: 60, launched: nil)]))
    }
}
