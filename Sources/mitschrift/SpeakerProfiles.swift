import CryptoKit
import Foundation
import Security

struct SpeakerProfile: Identifiable, Sendable, Codable {
    let id: UUID
    let name: String
    let consentedAt: Date
}

struct SpeakerProfileMatch: Sendable {
    let name: String
    let similarity: Float
}

enum SpeakerProfiles {
    private struct Record: Codable {
        var profile: SpeakerProfile
        var references: [[Float]]
    }

    private enum ProfileError: LocalizedError {
        case invalidConsent, insufficientReferences, inconsistentReferences
        case missingKey, invalidKey, invalidCiphertext, invalidReferences

        var errorDescription: String? {
            switch self {
            case .invalidConsent: "Name oder Einwilligungsdatum ist ungültig."
            case .insufficientReferences: "Für ein Sprecherprofil fehlen übereinstimmende Stimmproben."
            case .inconsistentReferences: "Die Stimmproben passen nicht zum gespeicherten Sprecherprofil."
            case .missingKey: "Der Schlüssel für die Sprecherprofile fehlt im Schlüsselbund."
            case .invalidKey: "Der Schlüssel für die Sprecherprofile ist ungültig."
            case .invalidCiphertext: "Die Sprecherprofile konnten nicht verschlüsselt werden."
            case .invalidReferences: "Die gespeicherten Stimmproben haben ein ungültiges Format."
            }
        }
    }

    private static let dimensions = 256
    private static let maxReferences = 8
    private static let refinementThreshold: Float = 0.60
    private static let participantThreshold: Float = 0.70
    private static let globalThreshold: Float = 0.75
    private static let minimumMargin: Float = 0.04
    private static let lock = NSLock()
    private static let file = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/mitschrift/speaker-profiles", isDirectory: true)
        .appendingPathComponent("profiles-v1.enc")
    private static let keyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.anpalahan.mitschrift",
        kSecAttrAccount as String: "speaker-profiles-aes-key-v1"
    ]

    static func list() throws -> [SpeakerProfile] {
        try lock.withLock { try load().map(\.profile) }
    }

    static func remember(name: String, consentedAt: Date, samples: [[Float]]) throws {
        let name = trimmedName(name)
        guard !name.isEmpty, consentedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ProfileError.invalidConsent
        }
        let key = name.lowercased()
        var distinct: [[Float]] = []
        for sample in sampledEmbeddings(samples) where !distinct.contains(sample) {
            distinct.append(sample)
        }
        guard !distinct.isEmpty else { throw ProfileError.insufficientReferences }

        try lock.withLock {
            var records = try load()
            if let index = records.firstIndex(where: { $0.profile.name.lowercased() == key }) {
                let record = records[index]
                let anchor = record.references[0]
                let consistent = distinct.filter {
                    cosine($0, anchor) >= refinementThreshold
                        && similarity($0, to: record.references) >= refinementThreshold
                }
                guard !consistent.isEmpty else { throw ProfileError.inconsistentReferences }
                let additions = consistent.filter { !record.references.contains($0) }
                let recent = Array(record.references.dropFirst()) + additions
                records[index] = Record(
                    profile: SpeakerProfile(id: record.profile.id, name: name,
                                            consentedAt: max(record.profile.consentedAt, consentedAt)),
                    references: [anchor] + Array(recent.suffix(maxReferences - 1))
                )
            } else {
                let clusters = distinct.map { anchor in
                    let neighbors = distinct.filter { $0 != anchor && cosine(anchor, $0) >= refinementThreshold }
                    return [anchor] + neighbors.sorted { cosine(anchor, $0) > cosine(anchor, $1) }
                }
                guard let cluster = clusters.max(by: { $0.count < $1.count }),
                      cluster.count >= 2, cluster.count * 5 >= distinct.count * 3 else {
                    throw ProfileError.insufficientReferences
                }
                records.append(Record(profile: SpeakerProfile(id: UUID(), name: name, consentedAt: consentedAt),
                                      references: Array(cluster.prefix(maxReferences))))
            }
            try save(records)
        }
    }

    static func delete(id: UUID) throws {
        try lock.withLock {
            var records = try load()
            guard let index = records.firstIndex(where: { $0.profile.id == id }) else { return }
            records.remove(at: index)
            try save(records)
        }
    }

    static func match(_ samples: [[Float]], participants: Set<String>) throws -> SpeakerProfileMatch? {
        let embeddings = sampledEmbeddings(samples)
        guard embeddings.count >= 5 else { return nil }
        let names = Set(participants.map { trimmedName($0).lowercased() })

        return try lock.withLock {
            let ranked = try load().map { record in
                let scores = embeddings.map { similarity($0, to: record.references) }
                let average = scores.reduce(0, +) / Float(scores.count)
                return (name: record.profile.name, scores: scores, average: average)
            }.sorted { $0.average > $1.average }

            guard let best = ranked.first else { return nil }
            let minimum = names.contains(best.name.lowercased()) ? participantThreshold : globalThreshold
            let competitors = ranked.dropFirst()
            guard best.average >= minimum,
                  competitors.first.map({ best.average - $0.average >= minimumMargin }) ?? true else { return nil }

            let votes = best.scores.indices.filter { index in
                best.scores[index] >= minimum && competitors.allSatisfy {
                    best.scores[index] - $0.scores[index] >= minimumMargin
                }
            }.count
            guard votes * 5 >= embeddings.count * 3 else { return nil }
            return SpeakerProfileMatch(name: best.name, similarity: best.average)
        }
    }

    private static func trimmedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func sampledEmbeddings(_ samples: [[Float]]) -> [[Float]] {
        let embeddings = samples.compactMap(normalized)
        let limit = 10
        guard embeddings.count > limit else { return embeddings }
        return (0..<limit).map { embeddings[$0 * (embeddings.count - 1) / (limit - 1)] }
    }

    private static func normalized(_ sample: [Float]) -> [Float]? {
        guard sample.count == dimensions, sample.allSatisfy(\.isFinite) else { return nil }
        let squaredNorm = sample.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squaredNorm > 0 else { return nil }
        let norm = squaredNorm.squareRoot()
        return sample.map { Float(Double($0) / norm) }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return min(1, max(-1, dot))
    }

    private static func similarity(_ sample: [Float], to references: [[Float]]) -> Float {
        let scores = references.map { cosine(sample, $0) }.sorted(by: >)
        return (scores[0] + scores[1]) / 2
    }

    private static func load() throws -> [Record] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        guard let key = try loadKey() else { throw ProfileError.missingKey }
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        let records = try JSONDecoder().decode([Record].self, from: plaintext)
        guard records.allSatisfy({ record in
            (2...maxReferences).contains(record.references.count)
                && record.references.allSatisfy { $0.count == dimensions }
        }) else { throw ProfileError.invalidReferences }
        return records
    }

    private static func save(_ records: [Record]) throws {
        let key = try loadKey() ?? createKey()
        let plaintext = try JSONEncoder().encode(records)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let data = box.combined else { throw ProfileError.invalidCiphertext }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
    }

    private static func loadKey() throws -> SymmetricKey? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard let data = result as? Data, data.count == 32 else { throw ProfileError.invalidKey }
        return SymmetricKey(data: data)
    }

    private static func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var query = keyQuery
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try loadKey() else { throw ProfileError.missingKey }
            return existing
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
}
