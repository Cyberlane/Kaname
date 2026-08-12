import Foundation
import Testing
@testable import KanameDesktop

struct DesktopAutomaticBackupTests {
    @Test
    func pbkdf2MatchesPublishedSHA256Vector() throws {
        let key = try PBKDF2SHA256.deriveKey(
            password: Data("password".utf8),
            salt: Data("salt".utf8),
            rounds: 1,
            outputByteCount: 32
        )
        #expect(hex(key) == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    @Test
    func encryptedBackupBundleRoundTripsAndDetectsWrongPassphrase() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace.json")
        try Data("workspace-state".utf8).write(to: workspace)
        let bundle = root.appendingPathComponent("source.kanamebackup", isDirectory: true)
        let backupID = UUID()
        _ = try DesktopRecoveryService().createBackup(
            at: bundle,
            sources: [.init(kind: .workspaceState, fileURL: workspace, archiveName: "workspace.json")],
            stateSchemaVersion: 17,
            backupID: backupID,
            createdAtUnixMillis: 1_234
        )
        let artifact = try DesktopEncryptedBackupBundleCodec.seal(
            bundleURL: bundle,
            passphrase: "a strong local backup passphrase"
        )
        #expect(artifact.backupID == backupID)
        #expect(artifact.sha256 == DesktopRecoveryService.sha256(artifact.data))
        let restored = root.appendingPathComponent("restored.kanamebackup", isDirectory: true)
        let manifest = try DesktopEncryptedBackupBundleCodec.open(
            artifact.data,
            passphrase: "a strong local backup passphrase",
            destination: restored
        )
        #expect(manifest.backupID == backupID)
        #expect(try DesktopRecoveryService().validateBackup(at: restored) == manifest)
        #expect(throws: DesktopWorkflowTransferError.invalidPassphrase) {
            try DesktopEncryptedBackupBundleCodec.open(
                artifact.data,
                passphrase: "the wrong backup passphrase",
                destination: root.appendingPathComponent("wrong.kanamebackup")
            )
        }
    }

    @Test
    func localTransportVerifiesListsDownloadsAndDeletesGenerations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalFolderDesktopBackupTransport(root: root)
        let data = Data("encrypted-generation".utf8)
        let digest = DesktopRecoveryService.sha256(data)
        let key = "kaname-backups/generations/1-test.kanamebackup.encrypted"
        try await transport.testConnection(prefix: "kaname-backups")
        try await transport.put(key: key, data: data, sha256: digest)
        #expect(try await transport.get(key: key) == data)
        let objects = try await transport.list(prefix: "kaname-backups")
        #expect(objects.map(\.key) == [key])
        try await transport.delete(key: key)
        #expect(try await transport.list(prefix: "kaname-backups").isEmpty)
    }

    @Test
    func retentionNeverRemovesTheThreeNewestGenerations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = LocalFolderDesktopBackupTransport(root: root)
        var configuration = DesktopAutomaticBackupConfiguration()
        configuration.localFolderPath = root.path
        configuration.retentionDays = 7
        let now = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<5 {
            let key = "kaname-backups/generations/\(index).kanamebackup.encrypted"
            let data = Data("generation-\(index)".utf8)
            try await transport.put(key: key, data: data, sha256: DesktopRecoveryService.sha256(data))
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index - 10) * 86_400)],
                ofItemAtPath: root.appendingPathComponent(key).path
            )
        }

        try await DesktopAutomaticBackupService().enforceRetention(
            transport: transport,
            configuration: configuration,
            now: now
        )

        #expect(try await transport.list(prefix: configuration.prefix).map(\.key) == [
            "kaname-backups/generations/2.kanamebackup.encrypted",
            "kaname-backups/generations/3.kanamebackup.encrypted",
            "kaname-backups/generations/4.kanamebackup.encrypted",
        ])
    }

    @Test
    func configurationIsOptInAndRemoteDestinationRequiresHTTPS() throws {
        let defaults = DesktopAutomaticBackupConfiguration()
        #expect(defaults.enabled == false)
        #expect(throws: DesktopAutomaticBackupError.invalidConfiguration) { try defaults.validated() }
        var remote = defaults
        remote.destination = .cloudflareR2
        remote.endpoint = "http://example.r2.cloudflarestorage.com"
        remote.bucket = "kaname-backups"
        #expect(throws: DesktopAutomaticBackupError.invalidConfiguration) { try remote.validated() }
        remote.endpoint = "https://example.r2.cloudflarestorage.com"
        #expect(try remote.validated().region == "auto")
    }

    @Test
    func s3SignerUsesR2PathStyleRegionAndSignedIntegrityMetadata() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = S3DesktopBackupTransport(
            endpoint: URL(string: "https://example.r2.cloudflarestorage.com")!,
            bucket: "kaname-backups",
            region: "auto",
            accessKeyID: "ACCESSKEY",
            secretAccessKey: "secret",
            now: { date }
        )
        let body = Data("ciphertext".utf8)
        let digest = DesktopRecoveryService.sha256(body)
        let request = try transport.signedRequest(
            method: "PUT",
            key: "kaname/generations/example.encrypted",
            queryItems: [],
            body: body,
            metadataSHA256: digest
        )
        #expect(request.url?.absoluteString == "https://example.r2.cloudflarestorage.com/kaname-backups/kaname/generations/example.encrypted")
        #expect(request.value(forHTTPHeaderField: "x-amz-meta-kaname-sha256") == digest)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("/auto/s3/aws4_request") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-meta-kaname-sha256") == true)
    }

    @Test
    func s3ListParserPreservesContinuationForCompleteRetentionScans() throws {
        let xml = Data("""
        <ListBucketResult>
          <IsTruncated>true</IsTruncated>
          <Contents>
            <Key>kaname-backups/generations/1.encrypted</Key>
            <LastModified>2026-08-12T01:02:03Z</LastModified>
            <Size>42</Size>
          </Contents>
          <NextContinuationToken>opaque+/token==</NextContinuationToken>
        </ListBucketResult>
        """.utf8)
        let parser = S3ListObjectsParser(data: xml)

        #expect(parser.parse())
        #expect(parser.isTruncated)
        #expect(parser.nextContinuationToken == "opaque+/token==")
        #expect(parser.objects.map(\.key) == ["kaname-backups/generations/1.encrypted"])
        #expect(parser.objects.first?.byteCount == 42)
    }

    private func temporaryDirectory() throws -> URL {
        try TestTemporaryDirectory.make(prefix: "kaname-backup-tests")
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
