import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MoobilityCore

private func canvas(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
}

private func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) throws {
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    let props: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
}

/// (r, g, b) at (x, y), y from the top.
private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let h = Int(image.extent.height)
    let rect = CGRect(x: x, y: h - 1 - y, width: 1, height: 1)
    CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: rect, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@Suite struct LibraryImageLoaderTests {
    /// Stored left half red, right half blue. Orientation 6 means "rotate 90° clockwise to display",
    /// so the stored left edge ends up on top.
    @Test func exifOrientation6IsUpright() throws {
        let image = canvas(200, 100) { c in
            c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            c.setFillColor(blue); c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        let url = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(image, to: url, type: .jpeg, orientation: 6)
        let loaded = try #require(LibraryImageLoader.background(at: url))
        #expect(loaded.extent.size == CGSize(width: 100, height: 200))
        let top = pixel(loaded, 50, 20), bottom = pixel(loaded, 50, 180)
        #expect(top.0 > 200 && top.2 < 80, "top \(top)")
        #expect(bottom.2 > 200 && bottom.0 < 80, "bottom \(bottom)")
    }

    @Test func heicDecodes() throws {
        let image = canvas(64, 64) { c in c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let url = tempURL("heic")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(image, to: url, type: .heic)
        #expect(LibraryImageLoader.background(at: url) != nil)
    }

    @Test func largeImageIsDownsampled() throws {
        let image = canvas(6000, 4000) { c in c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000)) }
        let url = tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(image, to: url, type: .png)
        let bg = try #require(LibraryImageLoader.background(at: url))
        #expect(max(bg.extent.width, bg.extent.height) == 2560)
        let thumb = try #require(LibraryImageLoader.thumbnail(at: url))
        #expect(max(thumb.width, thumb.height) == 640)
    }

    @Test func smallImageIsNotUpscaled() throws {
        let image = canvas(300, 200) { c in c.setFillColor(red); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) }
        let url = tempURL("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(image, to: url, type: .png)
        let bg = try #require(LibraryImageLoader.background(at: url))
        #expect(bg.extent.size == CGSize(width: 300, height: 200))
    }

    @Test func garbageReturnsNil() throws {
        let url = tempURL("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        #expect(LibraryImageLoader.background(at: url) == nil)
        #expect(LibraryImageLoader.thumbnail(at: url) == nil)
    }

    /// Review Focus: an SVG conforms to `.image` but ImageIO can't decode it.
    @Test func svgReturnsNil() throws {
        let url = tempURL("svg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8).write(to: url)
        #expect(LibraryImageLoader.background(at: url) == nil)
    }

    @Test func seasonImagesAgreeInTheFrame() throws {
        let images = try ["spring", "summer", "autumn", "winter"].map { name in
            try #require(LibraryImageLoader.background(at: repoRoot.appendingPathComponent("App/Seasons/\(name).jpg")))
        }
        for image in images { #expect(image.extent.size == CGSize(width: 1920, height: 1080)) }
        for (x, y) in [(15, 500), (960, 15), (960, 1040)] {
            let samples = images.map { pixel($0, x, y) }
            for s in samples {
                #expect(abs(s.0 - samples[0].0) <= 8 && abs(s.1 - samples[0].1) <= 8 && abs(s.2 - samples[0].2) <= 8, "\(x),\(y): \(samples)")
            }
        }
    }
}

@Suite struct RuleTextTests {
    let today = CivilDay(year: 2026, month: 11, day: 3)
    private func md(_ m: Int, _ d: Int) -> MonthDay { MonthDay(month: m, day: d) }

    @Test func chipTexts() {
        #expect(TimingRule.yearly(start: md(11, 1), end: md(11, 30)).chipText(from: today) == "Every year · Nov 1–30")
        #expect(TimingRule.yearly(start: md(12, 20), end: md(1, 5)).chipText(from: today) == "Every year · Dec 20–Jan 5")
        #expect(TimingRule.yearly(start: md(11, 20), end: md(11, 20)).chipText(from: today) == "Every year · Nov 20")
        #expect(TimingRule.holiday(id: .diwali, leadDays: 0).chipText(from: today) == "Holiday · Diwali (5 days)")
        #expect(TimingRule.holiday(id: .diwali, leadDays: 2).chipText(from: today) == "Holiday · Diwali (5 days, 2 before)")
        #expect(TimingRule.holiday(id: .thanksgivingUS, leadDays: 0).chipText(from: today) == "Holiday · Thanksgiving (US) (1 day)")
        #expect(TimingRule.weekly(days: [6], window: .timed(start: 900, end: 1080)).chipText(from: today) == "Every week · Fri 3–6 pm")
        #expect(TimingRule.weekly(days: [2, 4], window: .allDay).chipText(from: today) == "Every week · Mon, Wed")
        #expect(TimingRule.weekly(days: [6], window: .timed(start: 690, end: 810)).chipText(from: today) == "Every week · Fri 11:30 am–1:30 pm")
        #expect(TimingRule.everyDay.chipText(from: today) == "Every day")
    }

    @Test func holidayPastItsTable() {
        let later = CivilDay(year: 2031, month: 1, day: 1)
        #expect(TimingRule.holiday(id: .diwali, leadDays: 0).chipText(from: later) == "No dates after 2030")
    }
}
