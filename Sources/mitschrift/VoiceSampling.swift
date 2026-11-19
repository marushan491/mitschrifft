import CoreML
import FluidAudio
import Foundation

struct VoiceSampling {
    private static let maxReferences = 10
    private static let windowSeconds = 6.0
    private static let bufferSeconds = 12.0
    private static let sampleSpacing = 10.0

    struct Candidate: Sendable {
        let speaker: Int
        let start: TimeInterval
        let sampleRate: Double
        let samples: [Float]
    }

    private var samples: [Float] = []
    private var sampleRate = 0.0
    private var firstFrame = 0
    private var nextFrame = 0
    private var captureEnd: TimeInterval?
    private var classifiedUntil: TimeInterval = 0
    private var finalized: [SpeakerSpan] = []
    private var trailing: [SpeakerSpan] = []
    private var lastReferenceStart: [Int: TimeInterval] = [:]
    private(set) var references: [Int: [[Float]]] = [:]

    mutating func append(_ audio: [Float], sampleRate rate: Double,
                         at diarizerTime: TimeInterval, until diarizerEnd: TimeInterval,
                         captureTime: TimeInterval) {
        guard let lastSample = audio.last else { return }
        let start = Int((diarizerTime * rate).rounded())
        let frames = Int((diarizerEnd * rate).rounded()) - start
        guard frames > 0, abs(frames - audio.count) <= Int((rate / 1_000).rounded(.up)) else {
            discardAudio()
            return
        }
        if samples.isEmpty || rate != sampleRate || start != firstFrame + samples.count
            || captureEnd.map({ abs(captureTime - $0) > 0.002 }) == true {
            samples.removeAll()
            firstFrame = start
            nextFrame = start
            sampleRate = rate
        }
        captureEnd = captureTime + Double(audio.count) / rate

        let retained = Int((Self.bufferSeconds * rate).rounded())
        let padding = max(0, frames - audio.count)
        let incoming = audio.prefix(frames).suffix(retained - padding)
        if frames > retained {
            samples.removeAll()
            firstFrame = start + frames - retained
        }
        let capacity = retained + Int(rate.rounded())
        if samples.count + incoming.count + padding > capacity {
            let remove = samples.count + incoming.count + padding - retained
            samples.removeFirst(remove)
            firstFrame += remove
        }
        samples.append(contentsOf: incoming)
        samples.append(contentsOf: repeatElement(lastSample, count: padding))
        assert(firstFrame + samples.count == start + frames)
    }

    mutating func update(_ update: DiarizerTimelineUpdate, frameDuration: Double) {
        guard sampleRate > 0 else { return }
        let bufferStart = Double(firstFrame) / sampleRate
        finalized.removeAll { $0.end <= bufferStart }
        func span(_ segment: DiarizerSegment) -> SpeakerSpan {
            SpeakerSpan(speaker: segment.speakerIndex,
                        start: Double(segment.startFrame) * frameDuration,
                        end: Double(segment.endFrame) * frameDuration)
        }
        finalized += update.finalizedSegments.map(span).filter { $0.end > bufferStart }
        trailing = update.tentativeSegments.map(span).filter { $0.end > bufferStart }
        classifiedUntil = Double(update.chunkResult.tentativeStartFrame) * frameDuration
    }

    mutating func takeCandidate() -> Candidate? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        let windowFrames = Int((Self.windowSeconds * sampleRate).rounded())
        let classifiedEnd = Int((classifiedUntil * sampleRate).rounded())
        let bufferEnd = firstFrame + samples.count
        let spans = (finalized + trailing).map {
            (speaker: $0.speaker, start: Int(($0.start * sampleRate).rounded()),
             end: Int(($0.end * sampleRate).rounded()))
        }
        let boundaries = spans.flatMap { [$0.start, $0.end] }
        nextFrame = max(firstFrame, nextFrame)

        while nextFrame + windowFrames <= min(bufferEnd, classifiedEnd) {
            let frame = nextFrame
            let start = Double(frame) / sampleRate
            let end = frame + windowFrames
            nextFrame += max(1, Int((sampleRate / 2).rounded()))
            if let boundary = boundaries.lazy.filter({ $0 > frame }).min() {
                nextFrame = min(nextFrame, boundary)
            }
            guard let span = spans.first(where: {
                $0.start <= frame && $0.end >= end
            }), references[span.speaker, default: []].count < Self.maxReferences,
                start - (lastReferenceStart[span.speaker] ?? -.infinity) >= Self.sampleSpacing,
                !spans.contains(where: {
                    $0.speaker != span.speaker && $0.start < end && $0.end > frame
                }) else { continue }

            let index = frame - firstFrame
            let window = samples[index..<(index + windowFrames)]
            guard Self.hasUsableAudio(window, sampleRate: sampleRate) else { continue }
            return Candidate(speaker: span.speaker, start: start,
                             sampleRate: sampleRate, samples: Array(window))
        }
        return nil
    }

    mutating func store(_ embedding: [Float], for candidate: Candidate) {
        references[candidate.speaker, default: []].append(embedding)
        lastReferenceStart[candidate.speaker] = candidate.start
    }

    mutating func discardAudio() {
        samples.removeAll()
        finalized.removeAll()
        trailing.removeAll()
    }

    private static func hasUsableAudio(_ samples: ArraySlice<Float>, sampleRate: Double) -> Bool {
        let blockSize = max(1, Int((sampleRate / 10).rounded()))
        var blockPower: [Double] = []
        var clipped = 0
        for start in stride(from: samples.startIndex, to: samples.endIndex, by: blockSize) {
            let block = samples[start..<min(start + blockSize, samples.endIndex)]
            var sum = 0.0
            var squared = 0.0
            for value in block {
                guard value.isFinite else { return false }
                if abs(value) >= 0.995 { clipped += 1 }
                let sample = Double(value)
                sum += sample
                squared += sample * sample
            }
            let count = Double(block.count)
            let mean = sum / count
            blockPower.append(squared / count - mean * mean)
        }
        guard clipped * 1_000 <= samples.count else { return false }
        let levels = blockPower.sorted()
        let lower = levels[levels.count / 5]
        let upper = levels[levels.count * 4 / 5]
        return lower >= 0.000025 && upper >= lower * 2
    }
}

actor VoiceEmbeddingExtractor {
    private let converter = AudioConverter(sampleRate: 16_000)
    private var extractor: EmbeddingExtractor?
    private var mask: [[Float]] = []

    func embedding(for candidate: VoiceSampling.Candidate) async throws -> [Float]? {
        let audio = try converter.resample(candidate.samples, from: candidate.sampleRate)
        guard !audio.isEmpty else { return nil }
        if extractor == nil { try await loadModel() }
        guard let vector = try extractor?.getEmbeddings(audio: audio, masks: mask).first,
              vector.count == SpeakerManager.embeddingSize,
              vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }

    private func loadModel() async throws {
        let modelName = ModelNames.Diarizer.embeddingFile
        let directory = DiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.revision, isDirectory: true)
        let path = directory.appendingPathComponent(modelName, isDirectory: true)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model: MLModel
        if let cached = try? MLModel(contentsOf: path, configuration: configuration) {
            model = cached
        } else {
            try await ModelHub.download(.diarizer, subdirectory: modelName, to: directory)
            model = try MLModel(contentsOf: path, configuration: configuration)
        }
        guard let shape = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape,
              shape.count == 2, shape[1].intValue > 0 else {
            throw DiarizerError.embeddingExtractionFailed
        }
        mask = [[Float](repeating: 1, count: shape[1].intValue)]
        extractor = EmbeddingExtractor(embeddingModel: model)
    }
}
