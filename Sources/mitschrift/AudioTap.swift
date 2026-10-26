import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum Track: String, Sendable {
    case mic
    case system
}

struct TappedBuffer: @unchecked Sendable {
    let track: Track
    let buffer: AVAudioPCMBuffer
    let hostTime: CMTime
}

final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mitschrift.tap", qos: .userInitiated)
    private let sink: @Sendable (TappedBuffer) -> Void
    private let onStop: @Sendable (Error) -> Void

    init(sink: @escaping @Sendable (TappedBuffer) -> Void,
         onStop: @escaping @Sendable (Error) -> Void) {
        self.sink = sink
        self.onStop = onStop
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MitschriftError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 8
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let track: Track
        switch type {
        case .audio: track = .system
        case .microphone: track = .mic
        default: return
        }

        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let copied = Self.pcmBuffer(from: sampleBuffer) else { return }

        sink(TappedBuffer(track: track,
                          buffer: copied,
                          hostTime: sampleBuffer.presentationTimeStamp))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        return try? sampleBuffer.withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                  source.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength)
            else { return nil }

            copy.frameLength = source.frameLength

            let incoming = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: source.audioBufferList))
            let outgoing = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            guard incoming.count == outgoing.count else { return nil }

            for index in 0..<incoming.count {
                guard let from = incoming[index].mData, let to = outgoing[index].mData else { return nil }
                let bytes = min(Int(incoming[index].mDataByteSize), Int(outgoing[index].mDataByteSize))
                memcpy(to, from, bytes)
                outgoing[index].mDataByteSize = UInt32(bytes)
            }
            return copy
        }
    }
}
