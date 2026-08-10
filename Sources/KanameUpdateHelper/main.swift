import CryptoKit
import Foundation
#if os(macOS)
import Darwin
#endif

private enum UpdateHelperError: Error {
    case invalidArguments
    case invalidPath
    case parentDidNotExit
    case launchFailed
    case healthTimeout
    case trustValidationFailed
}

@main
private enum KanameUpdateHelper {
    static func main() {
        do {
            let values = try arguments(CommandLine.arguments)
            if CommandLine.arguments.contains("--switch") {
                try switchBundle(values)
            } else if CommandLine.arguments.contains("--rollback") {
                try rollback(values)
            } else {
                throw UpdateHelperError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("kaname-update-helper: update failed\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func switchBundle(_ values: [String: String]) throws {
        let installed = try appURL(values["--installed"])
        let staged = try appURL(values["--staged"])
        let backup = try appURL(values["--backup"])
        let health = try fileURL(values["--health"])
        let receipt = try fileURL(values["--receipt"])
        try validateUpdatePaths(installed: installed, staged: staged, backup: backup, replaced: nil, receipt: receipt)
        let pid = try processID(values["--pid"])
        let timeout = Double(values["--timeout"] ?? "12") ?? 12
        try waitForExit(pid: pid, timeout: timeout)
        try verifyStagedBundle(
            staged,
            expectedVersion: values["--version"],
            expectedBuild: values["--build"],
            expectedBundleDigest: values["--bundle-digest"],
            expectedSignerDigest: values["--signer-digest"]
        )
        try verifyStagedBundle(
            installed,
            expectedVersion: values["--rollback-version"],
            expectedBuild: values["--rollback-build"],
            expectedBundleDigest: values["--rollback-bundle-digest"],
            expectedSignerDigest: values["--rollback-signer-digest"]
        )
        try? FileManager.default.removeItem(at: health)
        try prepareParent(of: backup)
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: installed, to: backup)
        var launchedCandidatePID: Int32?
        do {
            try FileManager.default.moveItem(at: staged, to: installed)
            let launchedAfter = Int64(Date().timeIntervalSince1970 * 1_000)
            let launchedPID = try launchExecutable(
                in: installed,
                arguments: [
                    "--kaname-update-nonce", values["--health-nonce"] ?? "",
                    "--kaname-update-bundle-digest", values["--bundle-digest"] ?? "",
                ]
            )
            launchedCandidatePID = launchedPID
            try waitForHealth(
                at: health,
                version: values["--version"],
                build: values["--build"],
                channel: values["--channel"],
                processIdentifier: launchedPID,
                launchedAfterUnixMillis: launchedAfter,
                healthNonce: values["--health-nonce"],
                bundleDigest: values["--bundle-digest"],
                workspaceSchemaVersion: Int(values["--workspace-schema"] ?? ""),
                timeout: timeout
            )
            try writeReceipt(.healthy, detail: "The updated UI passed its health handshake. Rollback remains available.", to: receipt)
        } catch {
            if let launchedCandidatePID { terminateProcess(launchedCandidatePID) }
            try verifyStagedBundle(
                backup,
                expectedVersion: values["--rollback-version"],
                expectedBuild: values["--rollback-build"],
                expectedBundleDigest: values["--rollback-bundle-digest"],
                expectedSignerDigest: values["--rollback-signer-digest"]
            )
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.moveItem(at: backup, to: installed)
            try? FileManager.default.removeItem(at: health)
            let launchedAfter = Int64(Date().timeIntervalSince1970 * 1_000)
            let restoredPID = try launchExecutable(in: installed)
            try waitForHealth(
                at: health,
                version: values["--rollback-version"],
                build: values["--rollback-build"],
                channel: values["--channel"],
                processIdentifier: restoredPID,
                launchedAfterUnixMillis: launchedAfter,
                timeout: timeout
            )
            try writeReceipt(.rolledBack, detail: "The candidate missed its health deadline. Kaname restored the previous bundle.", to: receipt)
            throw error
        }
    }

    private static func rollback(_ values: [String: String]) throws {
        let installed = try appURL(values["--installed"])
        let backup = try appURL(values["--backup"])
        let health = try fileURL(values["--health"])
        let receipt = try fileURL(values["--receipt"])
        guard let currentDigest = values["--bundle-digest"],
              currentDigest.count == 64,
              currentDigest.allSatisfy(\Character.isHexDigit) else {
            throw UpdateHelperError.invalidArguments
        }
        let replaced = receipt.deletingLastPathComponent()
            .appending(path: "Replaced", directoryHint: .isDirectory)
            .appending(path: "\(currentDigest).app", directoryHint: .isDirectory)
        try validateUpdatePaths(
            installed: installed,
            staged: nil,
            backup: backup,
            replaced: replaced,
            receipt: receipt
        )
        let pid = try processID(values["--pid"])
        let timeout = Double(values["--timeout"] ?? "12") ?? 12
        try waitForExit(pid: pid, timeout: timeout)
        try verifyStagedBundle(
            installed,
            expectedVersion: values["--version"],
            expectedBuild: values["--build"],
            expectedBundleDigest: currentDigest,
            expectedSignerDigest: values["--signer-digest"]
        )
        try verifyStagedBundle(
            backup,
            expectedVersion: values["--rollback-version"],
            expectedBuild: values["--rollback-build"],
            expectedBundleDigest: values["--rollback-bundle-digest"],
            expectedSignerDigest: values["--rollback-signer-digest"]
        )
        guard !FileManager.default.fileExists(atPath: replaced.path) else {
            throw UpdateHelperError.invalidPath
        }
        try prepareParent(of: replaced)
        try FileManager.default.moveItem(at: installed, to: replaced)
        var restoredPID: Int32?
        do {
            try FileManager.default.moveItem(at: backup, to: installed)
            try? FileManager.default.removeItem(at: health)
            let launchedAfter = Int64(Date().timeIntervalSince1970 * 1_000)
            let launchedPID = try launchExecutable(in: installed)
            restoredPID = launchedPID
            try waitForHealth(
                at: health,
                version: values["--rollback-version"],
                build: values["--rollback-build"],
                channel: values["--channel"],
                processIdentifier: launchedPID,
                launchedAfterUnixMillis: launchedAfter,
                timeout: timeout
            )
            try writeReceipt(.rolledBack, detail: "The previous Kaname bundle is active.", to: receipt)
        } catch {
            if let restoredPID { terminateProcess(restoredPID) }
            try verifyStagedBundle(
                replaced,
                expectedVersion: values["--version"],
                expectedBuild: values["--build"],
                expectedBundleDigest: currentDigest,
                expectedSignerDigest: values["--signer-digest"]
            )
            if FileManager.default.fileExists(atPath: installed.path) {
                guard !FileManager.default.fileExists(atPath: backup.path) else {
                    throw UpdateHelperError.invalidPath
                }
                try prepareParent(of: backup)
                try FileManager.default.moveItem(at: installed, to: backup)
            }
            try FileManager.default.moveItem(at: replaced, to: installed)
            try? FileManager.default.removeItem(at: health)
            let launchedAfter = Int64(Date().timeIntervalSince1970 * 1_000)
            let currentPID = try launchExecutable(in: installed)
            try waitForHealth(
                at: health,
                version: values["--version"],
                build: values["--build"],
                channel: values["--channel"],
                processIdentifier: currentPID,
                launchedAfterUnixMillis: launchedAfter,
                timeout: timeout
            )
            try writeReceipt(.healthy, detail: "Rollback failed safely. The current Kaname bundle was restored.", to: receipt)
            throw error
        }
    }

    private enum ReceiptStatus: String { case healthy, rolledBack }

    private static func writeReceipt(_ status: ReceiptStatus, detail: String, to url: URL) throws {
        var payload = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        payload["status"] = status.rawValue
        payload["detail"] = detail
        payload["updatedAtUnixMillis"] = Int64(Date().timeIntervalSince1970 * 1_000)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func launchExecutable(in app: URL, arguments: [String] = []) throws -> Int32 {
        let info = app.appending(path: "Contents/Info.plist")
        guard let dictionary = NSDictionary(contentsOf: info),
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !executableName.isEmpty,
              !executableName.contains("/") else { throw UpdateHelperError.launchFailed }
        let executable = app.appending(path: "Contents/MacOS/\(executableName)").standardizedFileURL
        guard executable.path.hasPrefix(app.standardizedFileURL.path + "/"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateHelperError.launchFailed
        }
        let values = [executable.path] + arguments
        let storage = values.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        var child: pid_t = 0
        guard posix_spawn(&child, executable.path, nil, nil, &argv, environ) == 0 else {
            throw UpdateHelperError.launchFailed
        }
        return child
    }

    private static func waitForHealth(
        at url: URL,
        version: String?,
        build: String?,
        channel: String?,
        processIdentifier: Int32,
        launchedAfterUnixMillis: Int64,
        healthNonce: String? = nil,
        bundleDigest: String? = nil,
        workspaceSchemaVersion: Int? = nil,
        timeout: Double
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if healthMatches(
                at: url,
                version: version,
                build: build,
                channel: channel,
                processIdentifier: processIdentifier,
                launchedAfterUnixMillis: launchedAfterUnixMillis,
                healthNonce: healthNonce,
                bundleDigest: bundleDigest,
                workspaceSchemaVersion: workspaceSchemaVersion
            ) {
                let stabilityDeadline = Date().addingTimeInterval(min(0.75, max(0.25, timeout / 4)))
                while Date() < stabilityDeadline {
                    guard processIsRunning(processIdentifier), healthMatches(
                        at: url,
                        version: version,
                        build: build,
                        channel: channel,
                        processIdentifier: processIdentifier,
                        launchedAfterUnixMillis: launchedAfterUnixMillis,
                        healthNonce: healthNonce,
                        bundleDigest: bundleDigest,
                        workspaceSchemaVersion: workspaceSchemaVersion
                    ) else { throw UpdateHelperError.healthTimeout }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw UpdateHelperError.healthTimeout
    }

    private static func healthMatches(
        at url: URL,
        version: String?,
        build: String?,
        channel: String?,
        processIdentifier: Int32,
        launchedAfterUnixMillis: Int64,
        healthNonce: String?,
        bundleDigest: String?,
        workspaceSchemaVersion: Int?
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? String == version,
              object["build"] as? String == build,
              object["channel"] as? String == channel,
              (object["processID"] as? NSNumber)?.int32Value == processIdentifier,
              ((object["healthyAtUnixMillis"] as? NSNumber)?.int64Value ?? 0) >= launchedAfterUnixMillis,
              (healthNonce == nil || object["healthNonce"] as? String == healthNonce),
              (bundleDigest == nil || object["bundleDigest"] as? String == bundleDigest),
              (workspaceSchemaVersion == nil || (object["workspaceSchemaVersion"] as? NSNumber)?.intValue == workspaceSchemaVersion) else {
            return false
        }
        return true
    }

    private static func processIsRunning(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == 0
    }

    private static func terminateProcess(_ pid: Int32) {
        guard pid > 1 else { return }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }

    private static func waitForExit(pid: Int32, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw UpdateHelperError.parentDidNotExit
    }

    private static func verifyStagedBundle(
        _ bundle: URL,
        expectedVersion: String?,
        expectedBuild: String?,
        expectedBundleDigest: String?,
        expectedSignerDigest: String?
    ) throws {
        guard let expectedVersion, !expectedVersion.isEmpty,
              let expectedBuild, !expectedBuild.isEmpty,
              let expectedBundleDigest, expectedBundleDigest.count == 64,
              let expectedSignerDigest, expectedSignerDigest.count == 64,
              let dictionary = NSDictionary(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              dictionary["CFBundleShortVersionString"] as? String == expectedVersion,
              dictionary["CFBundleVersion"] as? String == expectedBuild,
              try bundleDigest(at: bundle) == expectedBundleDigest else {
            throw UpdateHelperError.trustValidationFailed
        }
        let verification = try capture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", bundle.path]
        )
        guard verification.status == 0 else { throw UpdateHelperError.trustValidationFailed }
        let requirement = try capture(
            executable: "/usr/bin/codesign",
            arguments: ["--display", "--requirements", "-", bundle.path]
        )
        let identity = (requirement.output + requirement.error)
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("designated =>") })
        guard requirement.status == 0,
              let identity,
              sha256(Data(identity.utf8)) == expectedSignerDigest else {
            throw UpdateHelperError.trustValidationFailed
        }
    }

    private static func bundleDigest(at bundle: URL) throws -> String {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: bundle.path) else {
            throw UpdateHelperError.trustValidationFailed
        }
        let entries = enumerator.compactMap { $0 as? String }
            .filter { !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }
            .sorted()
        var hash = SHA256()
        for relative in entries {
            let url = bundle.appending(path: relative)
            let attributes = try manager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = try manager.destinationOfSymbolicLink(atPath: url.path)
                guard !destination.hasPrefix("/"), !destination.split(separator: "/").contains("..") else {
                    throw UpdateHelperError.trustValidationFailed
                }
                hash.update(data: Data("link\u{0}\(relative)\u{0}\(destination)\u{0}".utf8))
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                hash.update(data: Data("file\u{0}\(relative)\u{0}".utf8))
                hash.update(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func capture(executable: String, arguments: [String]) throws -> (output: String, error: String, status: Int32) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            process.terminationStatus
        )
    }

    private static func arguments(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--switch" || key == "--rollback" { index += 1; continue }
            guard key.hasPrefix("--"), index + 1 < arguments.count else { throw UpdateHelperError.invalidArguments }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func processID(_ value: String?) throws -> Int32 {
        guard let value, let pid = Int32(value), pid > 1 else { throw UpdateHelperError.invalidArguments }
        return pid
    }

    private static func appURL(_ value: String?) throws -> URL {
        let url = try fileURL(value)
        guard url.pathExtension == "app", url.path != "/", !url.path.contains("/../") else {
            throw UpdateHelperError.invalidPath
        }
        return url
    }

    private static func fileURL(_ value: String?) throws -> URL {
        guard let value, value.hasPrefix("/"), value != "/" else { throw UpdateHelperError.invalidPath }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func prepareParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    private static func validateUpdatePaths(
        installed: URL,
        staged: URL?,
        backup: URL,
        replaced: URL?,
        receipt: URL
    ) throws {
        let updateRoot = canonicalPath(receipt.deletingLastPathComponent())
        let managed = [staged, backup, replaced].compactMap { $0 }
        guard !canonicalPath(installed).hasPrefix(updateRoot + "/"),
              managed.allSatisfy({ canonicalPath($0).hasPrefix(updateRoot + "/") }) else {
            throw UpdateHelperError.invalidPath
        }
        let urls = [installed] + managed
        let paths = urls.map(canonicalPath)
        guard Set(paths).count == paths.count else { throw UpdateHelperError.invalidPath }
        for (index, path) in paths.enumerated() {
            for other in paths.dropFirst(index + 1) {
                guard !path.hasPrefix(other + "/"), !other.hasPrefix(path + "/") else {
                    throw UpdateHelperError.invalidPath
                }
            }
        }
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw UpdateHelperError.invalidPath }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
