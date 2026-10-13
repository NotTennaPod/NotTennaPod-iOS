import Foundation
import Testing
@testable import NotTennaPodCore

private final class TranscriptScrollBundle {}
@Suite struct TranscriptScrollTests {
    struct Trace: Decodable {
        let density: Double, densityDpi: Double, rowHeightPx: Double, viewportPx: Double
        let cases: [Case]
        struct Case: Decodable {
            let startDP: Double, targetSegment: Int, follow: Bool, initial: Bool, initialAfter: Bool, endDP: Double, timedOut: Bool
            let frames: [Frame]
        }
        struct Frame: Decodable { let ms: Double, offsetDP: Double, state: Int }
    }
    private func trace(_ name: String) throws -> Trace {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
#else
        let url = try #require(Bundle(for: TranscriptScrollBundle.self).url(forResource: name, withExtension: "json"))
#endif
        return try JSONDecoder().decode(Trace.self, from: Data(contentsOf: url))
    }
    /// Auto-scroll lands where Android lands (within 2 pt) and never moves when Android does not;
    /// the per-frame animation curve is not compared.
    @Test(arguments: ["transcript-scroll-ordinary", "transcript-scroll-tall"])
    func originalRuntimeFinalPositions(name: String) throws {
        let trace = try trace(name), row = trace.rowHeightPx / trace.density, viewport = trace.viewportPx / trace.density
        for value in trace.cases {
            #expect(!value.timedOut)
            guard value.targetSegment > 0, value.follow || value.initial else {
                #expect(value.frames.allSatisfy { $0.offsetDP == value.startDP }); continue
            }
            let first = Int(floor(value.startDP / row)), target = Double(value.targetSegment - 1) * row
            let animation = TranscriptScrollAnimation(offset: value.startDP, targetTop: target,
                targetBottom: target + row, viewport: viewport, maximum: row * 50 - viewport,
                quick: abs(first - value.targetSegment) > 5, pixelsPerPoint: trace.density)
            #expect(abs(animation.targetOffset - value.endDP) < 2, "\(name), segment\(value.targetSegment)")
            let last = animation.value(at: 600)
            #expect(last.finished && abs(last.offset - animation.targetOffset) < 1)
        }
    }
    @Test func quickJumpFarTargetsAndClampAtContentEnd() {
        let ordinary = TranscriptScrollAnimation(offset: 0, targetTop: 48, targetBottom: 88,
            viewport: 220, maximum: 1780, quick: false, pixelsPerPoint: 2.625)
        #expect(ordinary.phases.count == 1)
        #expect(ordinary.value(at: 60).finished)
        // Far targets jump close first, then settle on the target.
        let quick = TranscriptScrollAnimation(offset: 0, targetTop: 760, targetBottom: 800,
            viewport: 220, maximum: 1780, quick: true, pixelsPerPoint: 3)
        #expect(abs(quick.initialOffset - 580) < 2)
        let reverse = TranscriptScrollAnimation(offset: 760, targetTop: 40, targetBottom: 80,
            viewport: 220, maximum: 1780, quick: true, pixelsPerPoint: 3)
        #expect(abs(reverse.initialOffset - 40) < 2 && reverse.value(at: 0).finished)
        // Never scrolls past the end of the content.
        let boundary = TranscriptScrollAnimation(offset: 1760, targetTop: 1920, targetBottom: 1960,
            viewport: 220, maximum: 1780, quick: false, pixelsPerPoint: 3)
        #expect(boundary.value(at: 0.25).finished && abs(boundary.value(at: 0.25).offset - 1780) < 0.5)
        for t in stride(from: 0.0, through: 5, by: 0.05) { #expect(boundary.value(at: t).offset <= 1780 + 0.5) }
    }
}
