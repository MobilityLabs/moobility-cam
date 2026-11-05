import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import MoobilityCore

private func solid(_ color: CIColor, _ w: CGFloat, _ h: CGFloat) -> CIImage {
    CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

private func makeBuffer(_ w: Int = 1280, _ h: Int = 720) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
}

/// (r, g, b) at pixel (x, y), y measured from the top row.
private func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let row = CVPixelBufferGetBaseAddress(pb)!.advanced(by: y * CVPixelBufferGetBytesPerRow(pb))
    let p = row.assumingMemoryBound(to: UInt8.self).advanced(by: x * 4)
    return (Int(p[2]), Int(p[1]), Int(p[0]))  // BGRA
}

private func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int = 3) -> Bool {
    abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol && abs(a.2 - b.2) <= tol
}

@Suite struct CompositorTests {
    let red = CIColor(red: 1, green: 0, blue: 0)
    let blue = CIColor(red: 0, green: 0, blue: 1)
    let white = CIColor(red: 1, green: 1, blue: 1)

    @Test func blendsPersonOverBackground() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let black = CIColor(red: 0, green: 0, blue: 0)
        let mask = solid(white, 640, 720).composited(over: solid(black, 1280, 720))  // full-frame mask, left half = person
        let out = c.composite(camera: solid(red, 1280, 720), mask: mask)
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 320, 360), (255, 0, 0)), "\(pixel(pb, 320, 360))")
        #expect(near(pixel(pb, 960, 360), (0, 0, 255)), "\(pixel(pb, 960, 360))")
    }

    /// Vision's mask is coarse, so its edge rarely lands on the person's real edge. The cut must follow the camera.
    @Test func maskEdgeFollowsTheCameraNotTheCoarseMask() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let black = CIColor(red: 0, green: 0, blue: 0)
        // Camera: bright person left of x = 640, dark room right of it.
        let camera = solid(white, 640, 720).composited(over: solid(black, 1280, 720))
        // A 64×36 mask whose edge is 1 cell late: it ends at x = 660 in output pixels.
        let mask = solid(white, 33, 36).composited(over: solid(black, 64, 36))
        let pb = makeBuffer()
        c.render(c.composite(camera: camera, mask: mask), into: pb)
        // Just right of the real edge is the dark room, inside the coarse mask's reach: it must be background.
        let room = pixel(pb, 650, 360)
        #expect(room.2 > 200 && room.0 < 40, "\(room)")
        let person = pixel(pb, 630, 360)
        #expect(near(person, (255, 255, 255), 20), "\(person)")
    }

    /// The faint rim of a mask is what leaves a halo of the room around a person.
    @Test func faintMaskValuesAreBackgroundAndStrongOnesArePerson() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let pb = makeBuffer()
        func shown(_ value: CGFloat) -> (Int, Int, Int) {
            let mask = solid(CIColor(red: value, green: value, blue: value), 1280, 720)
            c.render(c.composite(camera: solid(red, 1280, 720), mask: mask), into: pb)
            return pixel(pb, 640, 360)
        }
        let faint = shown(0.2)
        #expect(faint.0 < 12 && faint.2 > 240, "\(faint)")
        let strong = shown(0.95)
        #expect(strong.0 > 240 && strong.2 < 12, "\(strong)")
    }

    @Test func blendEnds() {
        let c = Compositor()
        let from = solid(red, 1280, 720), to = solid(blue, 1280, 720)
        let pb = makeBuffer()
        c.render(c.blend(from: from, to: to, mix: 0), into: pb)
        #expect(near(pixel(pb, 640, 360), (255, 0, 0)), "\(pixel(pb, 640, 360))")
        c.render(c.blend(from: from, to: to, mix: 1), into: pb)
        #expect(near(pixel(pb, 640, 360), (0, 0, 255)), "\(pixel(pb, 640, 360))")
        c.render(c.blend(from: from, to: to, mix: 0.5), into: pb)
        let mid = pixel(pb, 640, 360)
        #expect(mid.0 > 90 && mid.0 < 210 && mid.2 > 90 && mid.2 < 210, "\(mid)")
    }

    @Test func fourByThreeCameraIsCroppedNotStretched() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 318, y: 0, width: 4, height: 480))  // scales to x 636…644
        // Horizontal marker at source y 98…102 (from the bottom). Aspect-fill: ×2 then crop 120 → y 76…84.
        // A stretch (×1.5 vertically) would put it at y 147…153 instead.
        let row = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 0, y: 98, width: 640, height: 4))
        let camera = row.composited(over: green.composited(over: solid(red, 640, 480)))
        // Whole frame is "person", so the output is the camera after composite's crop (nil mask now means background).
        let out = c.composite(camera: camera, mask: solid(white, 640, 480))
        #expect(out.extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
        let pb = makeBuffer()
        c.render(out, into: pb)
        let (r, g, _) = pixel(pb, 640, 360)
        #expect(g > 200 && r < 60, "column 640 should be green, got \(pixel(pb, 640, 360))")
        #expect(near(pixel(pb, 600, 360), (255, 0, 0)), "\(pixel(pb, 600, 360))")
        let rowPixel = pixel(pb, 100, 720 - 80)   // pixel() counts rows from the top
        #expect(rowPixel.1 > 200 && rowPixel.0 < 60, "row marker should sit 80 px up, got \(rowPixel)")
        #expect(near(pixel(pb, 100, 720 - 150), (255, 0, 0)), "stretched position must be red, got \(pixel(pb, 100, 720 - 150))")
    }

    @Test func backgroundAspectFill() {
        let src = solid(blue, 1536, 1024)
        let filled = Compositor.aspectFill(src, to: Compositor.outputSize)
        #expect(filled.extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
        // 1536×1024 scales by 1.25 to 1920×1280; a marker at the source centre lands at the output centre.
        let marker = CIImage(color: CIColor(red: 1, green: 1, blue: 0))
            .cropped(to: CGRect(x: 764, y: 508, width: 8, height: 8))  // ~10 px at the output centre
        let filledMarked = Compositor.aspectFill(marker.composited(over: src), to: Compositor.outputSize)
        let c = Compositor()
        let pb = makeBuffer()
        c.render(filledMarked, into: pb)
        let (r, g, b) = pixel(pb, 640, 360)
        #expect(r > 200 && g > 200 && b < 60, "centre should be yellow, got \((r, g, b))")
    }

    /// Until a person mask exists the raw camera must never go out: send the background instead.
    @Test func nilMaskShowsBackgroundNotCamera() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let out = c.composite(camera: solid(red, 1280, 720), mask: nil)
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 640, 360), (0, 0, 255)), "\(pixel(pb, 640, 360))")
    }

    @Test func nilMaskWithoutBackgroundIsBlack() {
        let c = Compositor()
        let out = c.composite(camera: solid(red, 1280, 720), mask: nil)
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 640, 360), (0, 0, 0)), "\(pixel(pb, 640, 360))")
    }

    @Test func maskWithoutBackgroundPutsPersonOverBlack() {
        let c = Compositor()
        let black = CIColor(red: 0, green: 0, blue: 0)
        let mask = solid(white, 640, 720).composited(over: solid(black, 1280, 720))
        let out = c.composite(camera: solid(red, 1280, 720), mask: mask)
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 200, 360), (255, 0, 0)), "left \(pixel(pb, 200, 360))")
        #expect(near(pixel(pb, 1080, 360), (0, 0, 0)), "right \(pixel(pb, 1080, 360))")
    }

    @Test func plainIsTheCameraAspectFilled() {
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let out = c.plain(camera: solid(red, 640, 360))
        #expect(out.extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 640, 360), (255, 0, 0)), "\(pixel(pb, 640, 360))")
    }

    @Test func backgroundFrameIsBackgroundOrBlack() {
        let c = Compositor()
        let pb = makeBuffer()
        c.render(c.backgroundFrame(), into: pb)
        #expect(near(pixel(pb, 640, 360), (0, 0, 0)), "no background: \(pixel(pb, 640, 360))")
        c.setBackground(solid(blue, 1280, 720))
        #expect(c.backgroundFrame().extent == CGRect(x: 0, y: 0, width: 1280, height: 720))
        c.render(c.backgroundFrame(), into: pb)
        #expect(near(pixel(pb, 640, 360), (0, 0, 255)), "\(pixel(pb, 640, 360))")
    }

    @Test func onlyBackgroundOnlyModeLeavesTheWebcamOff() {
        #expect(CameraMode.overBackground.needsCamera)
        #expect(CameraMode.plainCamera.needsCamera)
        #expect(!CameraMode.backgroundOnly.needsCamera)
        #expect(CameraMode.allCases.count == 3)
    }

    @Test func lowResolutionMaskIsScaledToCamera() {
        // Vision returns a full-frame mask at lower resolution: 256×144, person = left half.
        let c = Compositor()
        c.setBackground(solid(blue, 1280, 720))
        let black = CIColor(red: 0, green: 0, blue: 0)
        let mask = solid(white, 128, 144).composited(over: solid(black, 256, 144))
        let out = c.composite(camera: solid(red, 1280, 720), mask: mask)
        let pb = makeBuffer()
        c.render(out, into: pb)
        #expect(near(pixel(pb, 320, 360), (255, 0, 0)), "\(pixel(pb, 320, 360))")
        #expect(near(pixel(pb, 960, 360), (0, 0, 255)), "\(pixel(pb, 960, 360))")
    }
}
