import Foundation

public enum KanameToolchainQualificationProcessError: Error {
    case inputOutOfBounds
    case processFailed(status: Int32, detail: String)
    case responseOutOfBounds
}

public enum KanameToolchainQualificationProcess {
    public static func argumentValue(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    public static func invoke(
        executable: URL,
        operation: String,
        input: Data,
        maximumInputBytes: Int = 512 * 1024,
        maximumResponseBytes: Int = 2 * 1024 * 1024
    ) throws -> Data {
        guard input.count <= maximumInputBytes else {
            throw KanameToolchainQualificationProcessError.inputOutOfBounds
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaname-toolchain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("stdout")
        let errorURL = scratch.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = executable
        process.arguments = [operation]
        process.standardInput = standardInput
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        try standardInput.fileHandleForWriting.write(contentsOf: input)
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        try outputHandle.synchronize()
        try errorHandle.synchronize()
        let output = try Data(contentsOf: outputURL, options: .mappedIfSafe)
        let error = try Data(contentsOf: errorURL, options: .mappedIfSafe)
        guard process.terminationStatus == 0 else {
            throw KanameToolchainQualificationProcessError.processFailed(
                status: process.terminationStatus,
                detail: String(decoding: error.prefix(512), as: UTF8.self)
            )
        }
        guard output.count <= maximumResponseBytes else {
            throw KanameToolchainQualificationProcessError.responseOutOfBounds
        }
        return output
    }
}
