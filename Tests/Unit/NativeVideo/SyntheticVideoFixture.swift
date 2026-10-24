import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Writes small real video files so the admission rule can be exercised
/// against AVFoundation rather than against a hand-made probe value.
///
/// Every clip is silent — most carry no audio track at all, and `withAudio`
/// adds one that holds linear PCM silence, written as file I/O, so nothing here
/// can touch audio hardware — and tiny, so writing one costs milliseconds. The
/// generator records the rate it was *asked* for; what a test reports is what
/// `NativeVideoAdmission.probe` reads back from the finished file, because the
/// two are not the same thing and conflating them would make the test assert
/// its own input.
enum SyntheticVideoFixture {
    struct Request {
        var name: String
        /// Presentation timestamps, as exact rationals. Frame-rate shape is
        /// expressed here rather than as a float, so 30000/1001 is written as
        /// 30000/1001 and not as 29.97.
        var timescale: CMTimeScale
        var frameDurations: [CMTimeValue]
        var width: Int = 64
        var height: Int = 36
        /// Adds an audio track of silence covering the whole clip, for the
        /// cases that are about a clip with sound.
        var withAudio = false
        /// How long the audio track lasts, when it should not end with the picture.
        var audioSeconds: Double?
        /// Clockwise quarter-turn multiples written as the track's display
        /// matrix, the way a phone records a portrait clip: the stored frames
        /// stay `width` x `height` and only the matrix says how to show them.
        var rotationDegrees = 0
        /// Writes the display matrix flipped left to right, the way a mirrored
        /// front-camera recording can carry it.
        var mirrored = false
        /// Paints each frame (the pixel buffer and the frame's index) in place of the default
        /// distinguishable-per-frame fill, for tests that need a particular picture.
        var painter: ((CVPixelBuffer, Int) -> Void)?

        /// Constant frame rate expressed exactly: `numerator / denominator`
        /// fps. 24 is 24/1, NTSC 30 is 30000/1001.
        static func constantRate(
            name: String, numerator: CMTimeValue, denominator: CMTimeValue, frames: Int
        ) -> Request {
            // One frame lasts denominator/numerator seconds. With the
            // timescale set to the numerator, that is exactly `denominator`
            // ticks.
            Request(
                name: name,
                timescale: CMTimeScale(numerator),
                frameDurations: Array(repeating: denominator, count: frames))
        }

        /// A clip whose average rate is `slowRate` fps but which contains a
        /// burst at `fastRate` fps: the case a nominal rate alone cannot see.
        static func variableRate(
            name: String, slowRate: CMTimeValue, fastRate: CMTimeValue, slowFrames: Int,
            fastFrames: Int
        ) -> Request {
            let timescale = CMTimeScale(slowRate * fastRate)
            var durations = Array(
                repeating: CMTimeValue(timescale) / slowRate, count: slowFrames)
            durations.append(
                contentsOf: Array(
                    repeating: CMTimeValue(timescale) / fastRate, count: fastFrames))
            return Request(name: name, timescale: timescale, frameDurations: durations)
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case writerFailed(String)
        case pixelBufferFailed
        case noInput
        case inputTimedOut

        var description: String {
            switch self {
            case let .writerFailed(detail): return "asset writer failed: \(detail)"
            case .pixelBufferFailed: return "could not create a pixel buffer"
            case .noInput: return "writer input never became ready"
            case .inputTimedOut: return "writer input readiness timed out"
            }
        }
    }

    static func waitUntilReady(
        isReady: () -> Bool, status: () -> AVAssetWriter.Status,
        failure: () -> String? = { nil }, timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isReady() {
            try Task.checkCancellation()
            guard status() == .writing else {
                throw FixtureError.writerFailed(failure() ?? "writer stopped before input became ready")
            }
            guard ContinuousClock.now < deadline else { throw FixtureError.inputTimedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Writes the clip and returns its URL. The caller owns the directory.
    static func write(_ request: Request, into directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("\(request.name).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: request.width,
            AVVideoHeightKey: request.height,
            // The hardware encoder is enabled by default, and these fixtures
            // are generated by the routine test gate, which is not a device
            // test. Eight 64x36 frames cost nothing in software, and this
            // keeps the gate off the media engine and independent of whether
            // one is available.
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        var matrix = CGAffineTransform.identity
        if request.rotationDegrees != 0 {
            matrix = CGAffineTransform(rotationAngle: CGFloat(request.rotationDegrees) * .pi / 180)
        }
        if request.mirrored { matrix = matrix.scaledBy(x: -1, y: 1) }
        if !matrix.isIdentity { input.transform = matrix }
        // Without this the writer picks its own media timescale — 600 in
        // practice — and 1001/24000 s per frame cannot be represented in it,
        // so an NTSC fixture silently becomes a whole-number one. Pinning the
        // track's timescale to the rate's own numerator is what makes
        // 30000/1001 survive into the file as 30000/1001.
        input.mediaTimeScale = request.timescale
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: request.width,
                kCVPixelBufferHeightKey as String: request.height,
            ])
        guard writer.canAdd(input) else { throw FixtureError.noInput }
        writer.add(input)
        let audio = request.withAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: nil) : nil
        if let audio {
            audio.expectsMediaDataInRealTime = false
            guard writer.canAdd(audio) else { throw FixtureError.noInput }
            writer.add(audio)
        }
        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // All of the audio goes in first and is finished, so the writer never
        // holds the video back waiting for audio to interleave with it.
        if let audio {
            let seconds = request.audioSeconds
                ?? Double(request.frameDurations.reduce(0, +)) / Double(request.timescale)
            let sample = try silence(frames: Int(silenceSampleRate * seconds))
            try await waitUntilReady(isReady: { audio.isReadyForMoreMediaData },
                status: { writer.status }, failure: { writer.error?.localizedDescription })
            guard audio.append(sample) else {
                throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "append audio")
            }
            audio.markAsFinished()
        }

        var elapsed: CMTimeValue = 0
        for (index, duration) in request.frameDurations.enumerated() {
            try await waitUntilReady(isReady: { input.isReadyForMoreMediaData },
                status: { writer.status }, failure: { writer.error?.localizedDescription })
            guard let pool = adaptor.pixelBufferPool else { throw FixtureError.pixelBufferFailed }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let pixelBuffer = buffer
            else { throw FixtureError.pixelBufferFailed }
            if let painter = request.painter { painter(pixelBuffer, index) } else { fill(pixelBuffer, step: index) }
            let time = CMTime(value: elapsed, timescale: request.timescale)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw FixtureError.writerFailed(
                    writer.error?.localizedDescription ?? "append rejected")
            }
            elapsed += duration
        }
        input.markAsFinished()
        // The last frame needs an end time, or the track's duration stops one
        // frame short and the final interval never reaches the metadata.
        var end = CMTime(value: elapsed, timescale: request.timescale)
        // A longer audio track would be cut off where the picture ends.
        if let seconds = request.audioSeconds, request.withAudio {
            end = CMTimeMaximum(end, CMTime(seconds: seconds, preferredTimescale: 44_100))
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.writerFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return url
    }

    /// A real movie with an audio track and no video track.
    ///
    /// Linear PCM written straight into the container: this is file I/O and
    /// arithmetic, it opens no audio device, configures no session and plays
    /// nothing. It exists so the "no video track" refusal is exercised against
    /// AVFoundation actually returning an empty video track list, rather than
    /// against a hand-built probe asserting itself.
    static func writeAudioOnly(name: String, into directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("\(name).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw FixtureError.noInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // A tenth of a second of silence is plenty to make a track exist.
        let frames = Int(silenceSampleRate / 10)
        let sample = try silence(frames: frames)
        try await waitUntilReady(isReady: { input.isReadyForMoreMediaData },
            status: { writer.status }, failure: { writer.error?.localizedDescription })
        guard input.append(sample) else {
            throw FixtureError.writerFailed(writer.error?.localizedDescription ?? "append audio")
        }
        input.markAsFinished()
        writer.endSession(
            atSourceTime: CMTime(
                value: CMTimeValue(frames), timescale: CMTimeScale(silenceSampleRate)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.writerFailed(
                writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return url
    }

    private static let silenceSampleRate = 44_100.0

    /// `frames` of mono 16-bit linear PCM silence as one sample buffer.
    private static func silence(frames: Int) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: silenceSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &formatDescription) == noErr,
            let formatDescription
        else { throw FixtureError.writerFailed("audio format description") }

        var samples = [Int16](repeating: 0, count: frames)
        var block: CMBlockBuffer?
        let byteCount = frames * MemoryLayout<Int16>.size
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
            let block,
            CMBlockBufferReplaceDataBytes(
                with: &samples, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: byteCount) == noErr
        else { throw FixtureError.writerFailed("audio block buffer") }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(silenceSampleRate)),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: [MemoryLayout<Int16>.size], sampleBufferOut: &sample) == noErr,
            let sample
        else { throw FixtureError.writerFailed("audio sample buffer") }
        return sample
    }

    /// Two silent H.264 frames in Matroska, which the compatibility demuxer can
    /// read even though AVFoundation does not accept the container. Embedding
    /// the original generated clip keeps tests independent of an FFmpeg CLI.
    /// Generated with: ffmpeg -f lavfi -i color=c=blue:s=16x16:r=24 -frames:v 2
    /// -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bsf:v filter_units=remove_types=6
    /// -fflags +bitexact -flags:v +bitexact -map_metadata -1 compatibility-h264.mkv
    static func writeMatroska(name: String, into directory: URL) throws -> URL {
        let encoded = """
            GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAACEhFNm3TAv4TpW94QTbuLU6uEFUmpZlOs
            gaFNu4tTq4QWVK5rU6yBzE27jFOrhBJUw2dTrIIBYE27jFOrhBxTu2tTrIIB9uwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZqa/hD3cjzUq
            17GDD0JATYCETGF2ZldBhExhdmZEiYhAVQAAAAAAABZUrmtAjr+EL1LyZa4BAAAAAAAAf9eBAXPFiAAAAAAAAAABnIEAIrWcg3Vu
            ZIiBAIaPVl9NUEVHNC9JU08vQVZDg4EBI+ODhAJ7yGrgkLCBELqBEJqBAlWwhFW5gQFV7oEA7AEAAAAAAAACAABjoqQBQsAK/+EA
            FWdCwAraewEQAAADABAAAAMDAPEiagEABGjOD8gSVMNn17+Ed7pbDXNzzmPAi2PFiAAAAAAAAAABZ8iZRaOHRU5DT0RFUkSHjExh
            dmMgbGlieDI2NGfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMDg0MDAwMDAwAB9DtnW1v4SkAW0b54EAo5uBAACAAAAAE2WIhDoR
            igACMXHAAEPKOAAIBeCjjYEAKgAAAAAFQZogJpQcU7trl7+E0Vo0b7uPs4EAt4r3gQHxggG88IEJ
            """
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw FixtureError.writerFailed("invalid embedded Matroska fixture")
        }
        let url = directory.appendingPathComponent("\(name).mkv")
        try data.write(to: url)
        return url
    }

    /// A file that is not a movie at all, for the corrupt-input case.
    static func writeCorrupt(name: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).mov")
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        return url
    }

    /// Distinguishable content per frame, so a poster test can tell two frames
    /// apart. Deliberately trivial: this is a fixture, not a renderer.
    private static func fill(_ buffer: CVPixelBuffer, step: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let level = UInt8((step * 17) % 256)
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let pixel = line.advanced(by: column * 4)
                pixel[0] = level
                pixel[1] = UInt8((row * 3) % 256)
                pixel[2] = UInt8((column * 5) % 256)
                pixel[3] = 255
            }
        }
    }
}
