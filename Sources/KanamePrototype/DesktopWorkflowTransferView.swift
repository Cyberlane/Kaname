import AppKit
import KanameDesktop
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum DesktopWorkflowTransferUI {
    static let packageType = UTType(exportedAs: "com.cyberlane.kaname.workflow")
    static let signedTemplateType = UTType(exportedAs: "com.cyberlane.kaname.workflow-template")
    static let installationType = UTType(exportedAs: "com.cyberlane.kaname.workflow-installation")

    static func installPackage(model: DesktopAppModel) throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Install Kaname workflow package"
        panel.message = "Choose a reusable workflow package or an encrypted private installation archive. Kaname reviews either locally and imports it disabled."
        panel.allowedContentTypes = [.json, packageType, signedTemplateType, installationType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let registered = Set(model.workflowCapabilityInstallations.filter(\.enabled).map(\.capabilityID))
            .union(model.snapshot.domains.skills.filter(\.enabled).map(\.id))
        if url.pathExtension.lowercased() == "kanameinstallation" {
            guard let passphrase = requestImportPassphrase() else { return nil }
            let payload = try model.previewWorkflowInstallation(data, passphrase: passphrase)
            guard confirmInstallationImport(payload) else { return nil }
            let workflowID = try model.importWorkflowInstallation(payload, registeredCapabilityIDs: registered)
            return "Imported \(workflowID) disabled. Rebind accounts and review capabilities, context, triggers, and effects before resuming."
        }
        if url.pathExtension.lowercased() == "kanametemplate" {
            let envelope = try JSONDecoder().decode(DesktopWorkflowSignedTemplateEnvelope.self, from: data)
            try DesktopWorkflowTemplateCodec.verify(envelope)
            guard confirmSignedTemplateImport(envelope) else { return nil }
            let revisionID = try model.installSignedWorkflowTemplate(
                envelopeData: data, registeredCapabilityIDs: registered
            )
            return "Verified and installed signed revision \(revisionID) disabled. Review configuration, exact dependency locks, and permissions before enabling."
        }

        let manifest = try DesktopWorkflowPackageCodec.decode(data, registeredCapabilityIDs: registered)
        let canonical = try DesktopWorkflowPackageCodec.canonicalData(manifest)
        let digest = DesktopWorkflowPackageCodec.digest(canonical)
        guard confirmPackageImport(manifest, digest: digest) else { return nil }
        let revisionID = try model.installWorkflowPackage(
            manifestData: canonical,
            registeredCapabilityIDs: registered,
            enable: false
        )
        return "Installed revision \(revisionID) disabled. Review every trigger, dependency, binding, and permission before enabling it."
    }

    static func exportPackage(model: DesktopAppModel, definition: DesktopWorkflowDefinitionRecord) throws -> String? {
        let data = try model.exportWorkflowPackage(workflowID: definition.id)
        let panel = NSSavePanel()
        panel.title = "Export reusable workflow package"
        panel.message = "This package contains behavior and permission declarations only. It contains no workflow runs, accounts, credentials, or private installation data."
        panel.prompt = "Export Package"
        panel.nameFieldStringValue = safeFilename(definition.name) + ".kanameworkflow"
        panel.allowedContentTypes = [packageType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return "Exported a reusable package without installation data or credentials."
    }

    static func exportInstallation(model: DesktopAppModel, definition: DesktopWorkflowDefinitionRecord) throws -> String? {
        guard let passphrase = requestPassphrase(
            title: "Protect private workflow installation",
            message: "Choose a passphrase with at least 12 characters. Kaname encrypts workflow history and referenced artifact bytes before writing the archive. The passphrase is not stored. You will need it to import the archive.",
            confirms: true
        ) else { return nil }
        let data = try model.exportWorkflowInstallation(workflowID: definition.id, passphrase: passphrase)
        let panel = NSSavePanel()
        panel.title = "Export encrypted workflow installation"
        panel.prompt = "Export Installation"
        panel.nameFieldStringValue = safeFilename(definition.name) + ".kanameinstallation"
        panel.allowedContentTypes = [installationType]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return "Exported an encrypted private installation archive. Its passphrase was not stored."
    }

    static func requestImportPassphrase() -> String? {
        requestPassphrase(
            title: "Unlock workflow installation",
            message: "Enter the passphrase used when this private installation archive was exported. Kaname will decrypt and inspect it locally before showing the import review.",
            confirms: false
        )
    }

    static func confirmPackageImport(_ manifest: DesktopWorkflowPackageManifest, digest: String) -> Bool {
        let permissionText = manifest.permissions.permissions.isEmpty
            ? "Local read-only"
            : manifest.permissions.permissions.map(\.label).joined(separator: "\n• ")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install \(manifest.name) disabled?"
        let requiredSlots = (manifest.bindingSlots ?? []).filter(\.required)
        let slotText = requiredSlots.isEmpty
            ? "No required private binding slots."
            : "Unresolved required slots:\n• " + requiredSlots.map { "\($0.label) (\($0.kind.label))" }.joined(separator: "\n• ")
        let dependencies = (manifest.dependencies ?? []).filter(\.required)
        let dependencyText = dependencies.isEmpty
            ? "No required package dependencies."
            : "Required dependencies:\n• " + dependencies.map { "\($0.kind.rawValue):\($0.id) \($0.versionRequirement)" }.joined(separator: "\n• ")
        alert.informativeText = "Version \(manifest.version) · manifest v\(manifest.schemaVersion) · \(manifest.steps.count) stages\nSource: \(manifest.source)\nPublisher: \(manifest.publisher?.name ?? "Legacy package")\nDigest: \(digest.prefix(20))…\n\nPermissions:\n• \(permissionText)\n\n\(slotText)\n\n\(dependencyText)\n\nThe package, installation, and triggers remain disabled until configuration and readiness review pass. No authority is inherited."
        alert.addButton(withTitle: "Install Disabled")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmSignedTemplateImport(_ envelope: DesktopWorkflowSignedTemplateEnvelope) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install verified template \(envelope.manifest.name) disabled?"
        alert.informativeText = "Version \(envelope.manifest.version) · signer \(envelope.signature.signerID)\nSigning key: \(envelope.signature.publicKeyFingerprint.prefix(20))…\nManifest: \(envelope.signature.manifestDigest.prefix(20))…\n\nKaname will cryptographically verify the exact manifest and publisher declaration before installation. Configuration, bindings, triggers, and authority remain disabled."
        alert.addButton(withTitle: "Verify and Install Disabled")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmInstallationImport(_ payload: DesktopWorkflowInstallationPayload) -> Bool {
        let state = payload.state
        let embedded = payload.artifacts.filter { $0.data != nil }.count
        let omitted = payload.artifacts.count - embedded
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import private installation disabled?"
        alert.informativeText = "\(payload.manifest.name) \(payload.manifest.version)\n\(state.workItems.count) work items · \(state.episodes.count) episodes · \(state.runs.count) runs\n\(embedded) embedded artifacts · \(omitted) unavailable artifacts\n\nThe workflow and every trigger will be disabled. Active runs and unexecuted effects will be cancelled. Account, capability, context, and effect authority must be reviewed before resuming."
        alert.addButton(withTitle: "Import Disabled")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func requestPassphrase(title: String, message: String, confirms: Bool) -> String? {
        let first = NSSecureTextField(string: "")
        first.placeholderString = "Passphrase"
        first.setAccessibilityLabel("Archive passphrase")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(first)
        var confirmation: NSSecureTextField?
        if confirms {
            let field = NSSecureTextField(string: "")
            field.placeholderString = "Confirm passphrase"
            field.setAccessibilityLabel("Confirm archive passphrase")
            stack.addArrangedSubview(field)
            confirmation = field
        }
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: confirms ? 56 : 24)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = stack
        alert.addButton(withTitle: confirms ? "Continue" : "Unlock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let passphrase = first.stringValue.precomposedStringWithCompatibilityMapping
        guard passphrase.utf8.count >= 12,
              passphrase.utf8.count <= 1_024,
              confirmation == nil || confirmation?.stringValue.precomposedStringWithCompatibilityMapping == passphrase else {
            let error = NSAlert()
            error.alertStyle = .warning
            error.messageText = "Passphrase not accepted"
            error.informativeText = confirms
                ? "Use at least 12 characters and enter the same passphrase twice."
                : "The passphrase must contain at least 12 characters."
            error.runModal()
            return nil
        }
        return passphrase
    }

    private static func safeFilename(_ value: String) -> String {
        let cleaned = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == " "
                ? String(character)
                : "-"
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Kaname Workflow" : String(cleaned.prefix(100))
    }
}
