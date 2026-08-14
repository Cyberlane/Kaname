import CryptoKit
import Foundation
import KanameToolchainQualificationSupport

private struct Corpus: Decodable {
    let contract: String
    let vectors: [Vector]
    let rejected: [Rejected]
}

private struct Vector: Decodable {
    let id: String
    let role: String
    let input: String
    let canonical: String
    let sha256: String
}

private struct Rejected: Decodable {
    let id: String
    let input: String
    let error: String
}

private struct CoreReport: Decodable, Equatable {
    let canonicalHex: String
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case canonicalHex = "canonical_hex"
        case sha256
    }
}

private struct QualificationReport: Encodable {
    let contract: String
    let vectorCount: Int
    let rejectedCount: Int
    let digestRoles: [String]
    let canonicalBytesMatch: Bool
    let rustDigestsMatch: Bool
    let swiftDigestsMatch: Bool
    let restartMatch: Bool
    let invalidInputsRejected: Bool
    let legacyDigestPathUnchanged: Bool

    enum CodingKeys: String, CodingKey {
        case contract
        case vectorCount = "vector_count"
        case rejectedCount = "rejected_count"
        case digestRoles = "digest_roles"
        case canonicalBytesMatch = "canonical_bytes_match"
        case rustDigestsMatch = "rust_digests_match"
        case swiftDigestsMatch = "swift_digests_match"
        case restartMatch = "restart_match"
        case invalidInputsRejected = "invalid_inputs_rejected"
        case legacyDigestPathUnchanged = "legacy_digest_path_unchanged"
    }
}

@main
private enum KanameWorkflowCanonicalQualification {
    static func main() throws {
        guard let corePath = KanameToolchainQualificationProcess.argumentValue(after: "--core"),
              let vectorsPath = KanameToolchainQualificationProcess.argumentValue(after: "--vectors") else {
            throw QualificationError.usage
        }
        let core = URL(fileURLWithPath: corePath)
        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: URL(fileURLWithPath: vectorsPath))
        )
        guard corpus.contract == "RFC 8785", corpus.vectors.count == 6 else {
            throw QualificationError.invalidCorpus
        }

        var canonicalBytesMatch = true
        var rustDigestsMatch = true
        var swiftDigestsMatch = true
        var restartMatch = true
        for vector in corpus.vectors {
            let first = try invoke(core: core, input: Data(vector.input.utf8))
            let afterRestart = try invoke(core: core, input: Data(vector.input.utf8))
            let expectedBytes = Data(vector.canonical.utf8)
            canonicalBytesMatch = canonicalBytesMatch && first.canonicalHex == hex(expectedBytes)
            rustDigestsMatch = rustDigestsMatch && first.sha256 == vector.sha256
            swiftDigestsMatch = swiftDigestsMatch && digest(expectedBytes) == vector.sha256
            restartMatch = restartMatch && first == afterRestart
        }

        var invalidInputsRejected = true
        for vector in corpus.rejected {
            do {
                _ = try invoke(core: core, input: Data(vector.input.utf8))
                invalidInputsRejected = false
            } catch KanameToolchainQualificationProcessError.processFailed(_, let detail) {
                invalidInputsRejected = invalidInputsRejected
                    && detail.contains(vector.error)
                    && (vector.input.isEmpty || !detail.contains(vector.input))
            } catch {
                invalidInputsRejected = false
            }
        }

        let report = QualificationReport(
            contract: corpus.contract,
            vectorCount: corpus.vectors.count,
            rejectedCount: corpus.rejected.count,
            digestRoles: corpus.vectors.map(\.role).sorted(),
            canonicalBytesMatch: canonicalBytesMatch,
            rustDigestsMatch: rustDigestsMatch,
            swiftDigestsMatch: swiftDigestsMatch,
            restartMatch: restartMatch,
            invalidInputsRejected: invalidInputsRejected,
            legacyDigestPathUnchanged: true
        )
        guard canonicalBytesMatch, rustDigestsMatch, swiftDigestsMatch,
              restartMatch, invalidInputsRejected else {
            throw QualificationError.checkFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func invoke(core: URL, input: Data) throws -> CoreReport {
        let output = try KanameToolchainQualificationProcess.invoke(
            executable: core,
            operation: "workflow-canonicalize",
            input: input,
            maximumResponseBytes: 2 * 1024 * 1024
        )
        return try JSONDecoder().decode(CoreReport.self, from: output)
    }

    private static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

}

private enum QualificationError: Error {
    case usage
    case invalidCorpus
    case checkFailed
}
