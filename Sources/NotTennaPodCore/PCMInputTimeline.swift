// Adapts Media3 1.10.0 DefaultAudioSink.handleBuffer input timestamp synchronization.
// Copyright (C) 2016 The Android Open Source Project.
// Apache License 2.0; see NOTICE.md and Licenses/Apache-2.0.txt.

/// Input accounting before silence/speed processing, after decoder-owned codec trimming.
/// This is not a presentation clock. Inspect without mutation while old processors drain;
/// submit only when the corresponding samples enter the new/current processor chain.
struct PCMInputTimeline: Sendable {
    enum Failure: Error, Equatable { case invalidRate, invalidFrames, overflow }
    struct Boundary: Equatable, Sendable {
        let expectedMicroseconds: Int64
        let adjustmentMicroseconds: Int64
        let requiresDrain: Bool
    }
    let sampleRate: Int
    private(set) var submittedFrames: Int64 = 0
    private(set) var anchorMicroseconds: Int64?

    init(sampleRate: Int) throws {
        guard (1...768_000).contains(sampleRate) else { throw Failure.invalidRate }
        self.sampleRate = sampleRate
    }

    func boundary(presentationMicroseconds: Int64, startsDecodedBuffer: Bool = true,
                  discontinuity: Bool = false) throws -> Boundary {
        let duration = Int128(submittedFrames) * 1_000_000 / Int128(sampleRate)
        let expected = Int128(anchorMicroseconds ?? max(0, presentationMicroseconds)) + duration
        guard let expectedUs = Int64(exactly: expected) else { throw Failure.overflow }
        let difference = Int128(presentationMicroseconds) - expected
        let sync = startsDecodedBuffer && ((anchorMicroseconds != nil && discontinuity) || abs(difference) > 200_000)
        guard let adjustment = Int64(exactly: sync ? difference : 0) else { throw Failure.overflow }
        return Boundary(expectedMicroseconds: expectedUs, adjustmentMicroseconds: adjustment, requiresDrain: sync)
    }

    mutating func submit(presentationMicroseconds: Int64, frames: Int,
                         startsDecodedBuffer: Bool = true, discontinuity: Bool = false,
                         trimmedFrames: Int = 0) throws {
        guard frames > 0, (0...frames).contains(trimmedFrames) else { throw Failure.invalidFrames }
        let decision = try boundary(presentationMicroseconds: presentationMicroseconds,
                                    startsDecodedBuffer: startsDecodedBuffer, discontinuity: discontinuity)
        let newAnchor = Int128(anchorMicroseconds ?? max(0, presentationMicroseconds))
            + Int128(decision.adjustmentMicroseconds)
        let newCount = Int128(submittedFrames) + Int128(frames - trimmedFrames)
        guard let anchor = Int64(exactly: newAnchor), let count = Int64(exactly: newCount) else { throw Failure.overflow }
        anchorMicroseconds = anchor
        submittedFrames = count
    }
}
