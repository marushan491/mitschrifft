import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class WindowVideo: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "mitschrift.video", qos: .userInitiated)
    private let lock = NSLock()
    private let url: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var opened = false
    private var frames = 0

    init(url: URL) {
        self.url = url
        super.init()
    }

    var frameCount: Int { lock.withLock { frames } }
    var fileName: String { url.lastPathComponent }

    func start(window: SCWindow, fps: Int, maxWidth: Int) async throws {
        let shrink = min(1.0, Double(maxWidth) / max(window.frame.width, 1))
        let width = max(16, Int((window.frame.width * shrink / 2).rounded()) * 2)
        let height = max(16, Int((window.frame.height * shrink / 2).rounded()) * 2)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 900_000,
                AVVideoMaxKeyFrameIntervalKey: max(fps, 1) * 5,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw MitschriftError.noCompatibleFormat }
        writer.add(input)
        self.writer = writer
        self.input = input

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.capturesAudio = false
        config.showsCursor = true
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: config,
                              delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log("Videoaufnahme laeuft: \(width)x\(height), \(fps) Bilder pro Sekunde, ohne Ton.")
    }

    func finish() async -> String? {
        if let stream { try? await stream.stopCapture() }
        stream = nil

        guard let writer, let input else { return nil }
        self.writer = nil
        self.input = nil

        let count = frameCount
        guard lock.withLock({ opened }), count > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            log("Video verworfen, kein Bild angekommen.")
            return nil
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            log("Video fehlgeschlagen: \(writer.error?.localizedDescription ?? "unbekannt")")
            return nil
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        log("Video gespeichert: \(url.lastPathComponent), \(count) Bilder, \((size ?? 0) / 1_048_576) MB.")
        return url.lastPathComponent
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil,
              let writer, let input
        else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        lock.lock()
        if !opened {
            guard writer.startWriting() else {
                lock.unlock()
                return
            }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            opened = true
        }
        lock.unlock()

        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else { return }
        lock.withLock { frames += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Videostrom beendet: \(error.localizedDescription)")
    }
}
