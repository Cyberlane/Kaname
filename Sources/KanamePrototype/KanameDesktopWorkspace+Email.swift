import KanameDesktop
import KanameDesktopUI
import KanameDesignSystem
import KanameWorkflowHost
import KanameConnectivity
import KanameDomain
import KanamePrototypeUI
import KanameLocalCore
import KanameLinkHost
import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct DesktopEmailView: View {
    @ObservedObject var model: DesktopAppModel
    @ObservedObject var integrations: DesktopPersonalIntegrationViewModel
    let allowsAutomaticInitialRead: Bool
    let openAutomations: () -> Void
    @StateObject private var mail = DesktopMailViewModel()
    @State private var showsComposer = false
    @State private var section = MailSection.inbox
    @State private var selectedAccountID: String?
    @State private var pendingMutation: GmailThreadMutation?
    @State private var pendingOutboundDraftID: String?
    @State private var pendingOutboundSend = false
    @State private var showsRuleSheet = false
    @State private var replySeed: MailReplySeed?
    @State private var workflowFilter = CommandLine.arguments.contains("--desktop-workflow-fixture") ? MailWorkflowFilter.active : .needsAttention
    @State private var workflowCollection = CommandLine.arguments.contains("--desktop-workflow-definitions") ? MailWorkflowCollection.definitions : .work
    @State private var selectedWorkflowWorkItemID: String?
    @State private var workflowImportMessage: String?
    @State private var capabilityImportMessage: String?
    @State private var manualRunDefinition: DesktopWorkflowDefinitionRecord?
    @State private var installationToConfigure: DesktopWorkflowInstallationRecord?
    @State private var workflowStudioDraftID: String?
    @State private var connectorToConfigure: DesktopWorkflowConnectorInstallationRecord?

    private var accounts: [DesktopAccountRecord] {
        model.snapshot.domains.accounts.filter { $0.service == .gmail }
    }

    private var googleAccounts: [NativeGoogleAccountSnapshot] {
        if let selectedAccountID { return integrations.googleAccounts.filter { $0.id == selectedAccountID } }
        return integrations.googleAccounts
    }

    private var activeAction: DesktopMailActionRecord? {
        mail.activeActionID.flatMap { id in model.snapshot.operations.mailActions.first { $0.id == id } }
    }

    private var activeApproval: DesktopApprovalRecord? {
        activeAction?.approvalID.flatMap { id in model.snapshot.operations.approvals.first { $0.id == id } }
    }

    var body: some View {
        emailWorkspace
        .background(KanameColor.canvas)
        .sheet(isPresented: $showsComposer) {
            NewEmailDraftSheet(model: model)
        }
        .sheet(isPresented: $showsRuleSheet) {
            NewMailRuleSheet(model: model, mail: mail, accounts: integrations.googleAccounts)
        }
        .sheet(item: $replySeed) { seed in
            NewEmailDraftSheet(
                model: model,
                accountID: seed.accountID,
                recipients: seed.recipients,
                subject: seed.subject,
                body: ""
            )
        }
        .sheet(item: $manualRunDefinition) { definition in
            WorkflowManualRunSheet(
                definition: definition,
                revision: model.snapshot.operations.workflows.revisions.first { $0.id == definition.currentRevisionID }
            ) { title, request, input in
                mail.runWorkflowManually(
                    model: model, workflowID: definition.id,
                    title: title, request: request, input: input
                )
            }
        }
        .sheet(item: $installationToConfigure) { installation in
            WorkflowInstallationSetupSheet(
                model: model,
                installation: installation,
                accounts: integrations.googleAccounts
            )
        }
        .sheet(isPresented: Binding(
            get: { workflowStudioDraftID != nil },
            set: { if !$0 { workflowStudioDraftID = nil } }
        )) {
            if let draftID = workflowStudioDraftID {
                WorkflowStudioSheet(model: model, draftID: draftID) { workflowID in
                    workflowImportMessage = "Published \(workflowID) disabled. Review bindings and authority before enabling it."
                    workflowCollection = .definitions
                }
            }
        }
        .sheet(item: $connectorToConfigure) { connector in
            WorkflowConnectorBindingSheet(model: model, connector: connector)
        }
        .onAppear {
            loadInitialMailDataIfNeeded()
        }
        .onChange(of: integrations.googleAccounts) {
            loadInitialMailDataIfNeeded()
        }
    }

    private func loadInitialMailDataIfNeeded() {
        let accounts = googleAccounts
        mail.loadLabels(accounts: accounts)
        guard allowsAutomaticInitialRead,
              mail.threads.isEmpty,
              !mail.isBusy,
              !accounts.isEmpty else { return }
        mail.search(accounts: accounts, model: model)
    }

    private var emailWorkspace: some View {
        VStack(spacing: 0) {
            SurfaceHeader(
                title: "Email",
                detail: "Account-isolated Gmail search, complete threads, local drafts, and reconciled actions",
                symbol: DesktopDestination.email.symbol
            )
            .padding(24)

            HStack {
                Text("View").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $section) {
                    ForEach(MailSection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                Text("Account").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Picker("", selection: $selectedAccountID) {
                    Text("All accounts").tag(String?.none)
                    ForEach(integrations.googleAccounts) { Text($0.identity).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                Menu {
                    Button("New local draft", systemImage: "square.and.pencil") { showsComposer = true }
                    Button("Refresh current search", systemImage: "arrow.clockwise") {
                        mail.search(accounts: googleAccounts, model: model)
                    }
                    .disabled(mail.isBusy || googleAccounts.isEmpty)
                    Divider()
                    Button("Open Automations", systemImage: DesktopDestination.automations.symbol) {
                        openAutomations()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Email actions")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()

            switch section {
            case .inbox: inboxWorkspace
            case .drafts: draftsWorkspace
            }
        }
        .onChange(of: selectedAccountID) { _, accountID in
            accountScopeChanged(to: accountID)
        }
    }

    private var inboxWorkspace: some View {
        HSplitView {
            mailThreadList.frame(minWidth: 300, idealWidth: 370, maxWidth: 460)

            threadDetail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mailThreadList: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Gmail search (for example: in:inbox is:unread)", text: $mail.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { mail.search(accounts: googleAccounts, model: model) }
                Button("Run", systemImage: "magnifyingglass") { mail.search(accounts: googleAccounts, model: model) }
                    .labelStyle(.iconOnly)
            }
            .padding([.horizontal, .top], 16)

            if !googleAccounts.isEmpty {
                mailLabelBrowser
            }

            if let loadFailure = integrations.googleAccountLoadFailure,
               integrations.googleAccounts.isEmpty {
                VStack(spacing: 12) {
                    EmptyPanel(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "Saved Gmail accounts unavailable",
                        detail: loadFailure
                    )
                    Button("Retry saved accounts", systemImage: "arrow.clockwise") {
                        integrations.retrySavedGoogleAccounts(model: model)
                    }
                    .disabled(integrations.isRefreshingGoogle)
                }
                .padding(16)
            } else if integrations.googleAccounts.isEmpty {
                EmptyPanel(
                    symbol: "person.crop.circle.badge.plus",
                    title: "No Gmail account connected",
                    detail: "Connect Google from Settings before searching Gmail."
                )
                .padding(16)
            } else if mail.isBusy, mail.threads.isEmpty {
                ProgressView("Reading Gmail…").frame(maxHeight: .infinity)
            } else if mail.threads.isEmpty {
                EmptyPanel(
                    symbol: "tray",
                    title: "No matching threads",
                    detail: "Search one or all connected accounts. Every result keeps its source account."
                )
                .padding(16)
            } else {
                List(selection: mailThreadSelection) {
                    ForEach(mail.threads, id: \.stableID) { thread in
                        MailThreadRow(thread: thread)
                            .tag(thread.stableID)
                            .onTapGesture {
                                pendingMutation = mail.select(thread, model: model)
                            }
                    }
                }
                if mail.hasNextPage {
                    Button("Load next page") { mail.search(accounts: googleAccounts, model: model, loadMore: true) }
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var mailLabelBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Folders & labels", systemImage: "tray.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let selection = mail.selectedLabel {
                    Text(selection.label.name)
                        .font(.caption)
                        .foregroundStyle(KanameColor.accent)
                        .lineLimit(1)
                    Button {
                        mail.clearLabelSelection()
                        mail.search(accounts: googleAccounts, model: model)
                    } label: {
                        Label("Clear \(selection.label.name)", systemImage: "xmark.circle.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Clear folder or label filter")
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(googleAccounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.identity)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(KanameColor.accent)
                                .lineLimit(1)
                            if mail.labelLoadingAccountIDs.contains(account.id), mail.labels[account.id] == nil {
                                ProgressView("Loading folders…").controlSize(.small)
                            } else if let error = mail.labelErrors[account.id] {
                                LabeledContent {
                                    Button("Retry") { mail.loadLabels(accounts: [account], force: true) }
                                        .controlSize(.small)
                                } label: {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            } else {
                                mailLabelGroup(
                                    title: "Folders",
                                    labels: labels(for: account, type: "system"),
                                    account: account
                                )
                                mailLabelGroup(
                                    title: "Labels",
                                    labels: labels(for: account, type: "user"),
                                    account: account
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func mailLabelGroup(
        title: String,
        labels: [GmailLabelSnapshot],
        account: NativeGoogleAccountSnapshot
    ) -> some View {
        if !labels.isEmpty {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 5)], alignment: .leading, spacing: 5) {
                ForEach(labels) { label in
                    let isSelected = mail.selectedLabel?.accountID == account.id
                        && mail.selectedLabel?.label.id == label.id
                    Button {
                        selectedAccountID = account.id
                        mail.setAccountScope(account.id)
                        mail.selectLabel(accountID: account.id, label: label)
                        mail.search(accounts: [account], model: model)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: labelSymbol(label.id))
                            Text(label.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected ? KanameColor.accent.opacity(0.28) : KanameColor.raised,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func labels(for account: NativeGoogleAccountSnapshot, type: String) -> [GmailLabelSnapshot] {
        (mail.labels[account.id] ?? [])
            .filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }
            .sorted { left, right in
                if type == "system" {
                    let order = ["INBOX", "STARRED", "IMPORTANT", "SENT", "DRAFT", "ALL_MAIL", "SPAM", "TRASH"]
                    let leftIndex = order.firstIndex(of: left.id) ?? order.count
                    let rightIndex = order.firstIndex(of: right.id) ?? order.count
                    if leftIndex != rightIndex { return leftIndex < rightIndex }
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func labelSymbol(_ id: String) -> String {
        let systemLabelSymbols = [
            "INBOX": "tray",
            "STARRED": "star",
            "IMPORTANT": "exclamationmark.circle",
            "SENT": "paperplane",
            "DRAFT": "doc",
            "SPAM": "exclamationmark.shield",
            "TRASH": "trash",
        ]
        return systemLabelSymbols[id] ?? "tag"
    }

    private func accountScopeChanged(to accountID: String?) {
        mail.setAccountScope(accountID)
        let scopedAccounts = accountID.map { id in
            integrations.googleAccounts.filter { $0.id == id }
        } ?? integrations.googleAccounts
        mail.loadLabels(accounts: scopedAccounts)
        if allowsAutomaticInitialRead, !scopedAccounts.isEmpty {
            mail.search(accounts: scopedAccounts, model: model)
        }
    }

    private var mailThreadSelection: Binding<String?> {
        Binding(
            get: { mail.selectedThread?.stableID },
            set: { stableID in
                guard let stableID, let thread = mail.threads.first(where: { $0.stableID == stableID }) else { return }
                pendingMutation = mail.select(thread, model: model)
            }
        )
    }

    @ViewBuilder
    private var threadDetail: some View {
        if let thread = mail.selectedThread {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(thread.messages.last?.subject ?? "(No subject)").font(.title2.weight(.bold))
                            Text(thread.accountIdentity).font(.caption).foregroundStyle(KanameColor.accent)
                            Text("\(thread.messages.count) message(s) · \(thread.labels.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ControlGroup {
                            Button("Refresh", systemImage: "arrow.clockwise") { mail.refreshSelected(model: model) }
                            Button("Summarize", systemImage: "text.quote") { mail.summarize(thread) }
                            Button("Draft reply", systemImage: "arrowshape.turn.up.left") {
                                replySeed = replySeed(for: thread)
                            }
                            Button("Archive", systemImage: "archivebox") {
                                pendingMutation = .archive
                                mail.proposeThreadMutation(
                                    model: model,
                                    thread: thread,
                                    mutation: .archive,
                                    preview: "Remove Inbox from this thread in \(thread.accountIdentity).",
                                    kind: .archive
                                )
                            }
                            Button("Trash", systemImage: "trash") {
                                pendingMutation = .trash
                                mail.proposeThreadMutation(
                                    model: model,
                                    thread: thread,
                                    mutation: .trash,
                                    preview: "Move this thread to Gmail Trash in \(thread.accountIdentity).",
                                    kind: .trash
                                )
                            }
                            Menu("Label", systemImage: "tag") {
                                ForEach(mail.labels[thread.accountID] ?? []) { label in
                                    Button(label.name) {
                                        let alreadyApplied = thread.labels.contains(label.id)
                                        let mutation = GmailThreadMutation.applyLabels(
                                            add: alreadyApplied ? [] : [label.id],
                                            remove: alreadyApplied ? [label.id] : []
                                        )
                                        pendingMutation = mutation
                                        mail.proposeThreadMutation(
                                            model: model,
                                            thread: thread,
                                            mutation: mutation,
                                            preview: "\(alreadyApplied ? "Remove" : "Add") label \(label.name) \(alreadyApplied ? "from" : "to") this thread in \(thread.accountIdentity).",
                                            kind: .labels
                                        )
                                    }
                                }
                            }
                        }
                        .controlGroupStyle(.navigation)
                    }

                    if let summary = mail.localSummary {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Private on-device summary", systemImage: "lock.shield")
                                .font(.headline)
                            Text(summary).textSelection(.enabled)
                        }
                        .panelStyle()
                    }

                    workflowAssociations(thread: thread)

                    ForEach(thread.messages) { message in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(message.sender).font(.headline)
                                Spacer()
                                Text(message.dateDescription).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text("To: \(message.recipients)").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            MailReaderBody(message: message)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !message.attachments.isEmpty {
                                HStack {
                                    ForEach(message.attachments) { attachment in
                                        Button(attachment.filename, systemImage: "paperclip") {
                                            mail.saveAttachment(accountID: thread.accountID, attachment: attachment)
                                        }
                                        .help("Download \(attachment.size) bytes, then choose where to save")
                                    }
                                }
                            }
                        }
                        .panelStyle()
                    }

                    actionReview
                    mailStatus
                }
                .padding(20)
            }
        } else {
            EmptyPanel(symbol: "envelope.open", title: "Choose a thread", detail: "Read the complete account-scoped conversation, attachments, labels, and action history here.")
                .padding(24)
        }
    }

    private var draftsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BoundaryCallout(
                    title: "Local until you decide",
                    detail: "Creating a Gmail draft and sending are separate exact actions. Send is never covered by a standing rule."
                )
                if model.snapshot.domains.emailDrafts.isEmpty {
                    EmptyPanel(symbol: "doc.badge.plus", title: "No local drafts", detail: "Compose locally without touching Gmail, then preview a remote draft or send.")
                }
                ForEach(model.snapshot.domains.emailDrafts.sorted { $0.updatedAtUnixMillis > $1.updatedAtUnixMillis }) { draft in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(draft.subject.isEmpty ? "Untitled draft" : draft.subject).font(.headline)
                            Spacer()
                            KanameStatusBadge(
                                KanameDesktopStatusPresentation.record(draft.status),
                                density: .compact
                            )
                        }
                        LabeledContent("Recipients", value: draft.recipients.isEmpty ? "None" : draft.recipients)
                        Text(draft.body).foregroundStyle(.secondary).lineLimit(6)
                        if let account = googleAccount(for: draft) {
                            Text("From \(account.identity)").font(.caption).foregroundStyle(KanameColor.accent)
                            HStack {
                                Button("Review Gmail draft") {
                                    pendingOutboundDraftID = draft.id
                                    pendingOutboundSend = false
                                    mail.proposeOutbound(model: model, draft: draft, account: account, send: false)
                                }
                                Button("Review send") {
                                    pendingOutboundDraftID = draft.id
                                    pendingOutboundSend = true
                                    mail.proposeOutbound(model: model, draft: draft, account: account, send: true)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(draft.recipients.isEmpty || draft.body.isEmpty)
                            }
                        } else {
                            Label("Choose or reconnect the draft account before any Gmail action.", systemImage: "person.crop.circle.badge.exclamationmark")
                                .font(.caption).foregroundStyle(KanameColor.warning)
                        }
                    }
                    .panelStyle()
                }
                actionReview
                mailStatus
            }
            .padding(24)
        }
    }

    private var workflowsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workflow operations").font(.headline)
                        Text("Manual checks and package operations stay visible under Automations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check triggers", systemImage: "arrow.triangle.2.circlepath") {
                        mail.checkWorkflowTriggers(model: model)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.workflowTriggerBindings().contains(where: { $0.enabled && $0.trigger == .email }))
                }
                BoundaryCallout(
                    title: "Generic workflows, private behavior",
                    detail: "Kaname supplies durable work, context, checks, approvals, effects, and observability. Installed packages supply domain behavior; email content can never broaden their authority."
                )
                workflowOperationalSummary
                Picker("Workflow collection", selection: $workflowCollection) {
                    ForEach(MailWorkflowCollection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                switch workflowCollection {
                case .work: workflowWorkList
                case .definitions: workflowDefinitionList
                case .simpleRules: simpleRuleList
                }
                if let workflowImportMessage { BoundaryCallout(title: "Workflow package", detail: workflowImportMessage) }
                mailStatus
            }
            .padding(24)
        }
    }

    private var workflowOperationalSummary: some View {
        let health = model.workflowTriggerHealth
        let actionRequired = health.filter { $0.state == .actionRequired }.count
        let degraded = health.filter { $0.state == .degraded }.count
        let waiting = model.snapshot.operations.workflows.waitSubscriptions.filter { $0.state == .active }.count
        let operational = model.activeWorkflowOperationalStatuses
        let operationalAction = operational.filter { $0.level == .actionRequired }.count
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(health.filter { $0.state != .healthy && $0.state != .paused }) { record in
                    LabeledContent(record.errorSummary ?? record.state.label) {
                        Text(record.state.label).foregroundStyle(record.state == .actionRequired ? KanameColor.warning : .secondary)
                    }
                }
                ForEach(mail.workflowComponentIssues, id: \.self) { issue in
                    Label(issue, systemImage: "puzzlepiece.extension.fill")
                        .font(.caption).foregroundStyle(KanameColor.warning)
                }
                ForEach(operational) { record in
                    Label(record.summary, systemImage: record.level == .actionRequired ? "exclamationmark.shield.fill" : "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(record.level == .actionRequired ? KanameColor.warning : .secondary)
                }
                if health.isEmpty && mail.workflowComponentIssues.isEmpty && operational.isEmpty {
                    Text("Health appears after the first enabled trigger check. Manual-only workflows stay quiet here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 14) {
                Label(actionRequired == 0 ? "No trigger action required" : "\(actionRequired) action required",
                      systemImage: actionRequired == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(actionRequired == 0 ? KanameColor.success : KanameColor.warning)
                if degraded > 0 { Text("\(degraded) retrying").foregroundStyle(.secondary) }
                if waiting > 0 { Text("\(waiting) waiting").foregroundStyle(KanameColor.active) }
                if operationalAction > 0 { Text("\(operationalAction) operation alert\(operationalAction == 1 ? "" : "s")").foregroundStyle(KanameColor.warning) }
                Spacer()
                Text("Details").font(.caption).foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(KanameColor.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var workflowWorkList: some View {
        Picker("Work state", selection: $workflowFilter) {
            ForEach(MailWorkflowFilter.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 520)

        let items = filteredWorkflowItems
        if items.isEmpty {
            EmptyPanel(
                symbol: workflowFilter.symbol,
                title: workflowFilter.emptyTitle,
                detail: "Work appears here only after a generic workflow is installed and an event is deliberately associated. Ordinary email remains uncluttered."
            )
        } else {
            ForEach(items) { item in
                WorkflowWorkItemCard(
                    model: model,
                    item: item,
                    expanded: selectedWorkflowWorkItemID == item.id,
                    requestEffectApproval: { mail.requestWorkflowEffectApproval(model: model, effect: $0) },
                    executeEffect: { mail.executeWorkflowEffect(model: model, effect: $0) },
                    completeHumanReview: { mail.completeWorkflowHumanReview(model: model, runID: $0, stepID: $1) },
                    toggleExpanded: {
                        selectedWorkflowWorkItemID = selectedWorkflowWorkItemID == item.id ? nil : item.id
                    }
                )
                .onAppear {
                    if selectedWorkflowWorkItemID == nil,
                       CommandLine.arguments.contains("--desktop-workflow-fixture") {
                        selectedWorkflowWorkItemID = item.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var workflowDefinitionList: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if !model.snapshot.operations.workflows.connectorInstallations.isEmpty {
                    Text("Trusted connectors").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.connectorInstallations) { connector in
                        WorkflowConnectorInstallationRow(
                            model: model, connector: connector,
                            onConfigure: { connectorToConfigure = connector }
                        )
                    }
                }
                if !model.snapshot.operations.workflows.rendererInstallations.isEmpty {
                    Text("Renderers and recalculation adapters").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.rendererInstallations) { renderer in
                        WorkflowRendererInstallationRow(model: model, renderer: renderer)
                    }
                }
                if !model.snapshot.operations.workflows.subflows.isEmpty {
                    Text("Reusable subflows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.snapshot.operations.workflows.subflows) { subflow in
                        LabeledContent("\(subflow.name) · \(subflow.version)") {
                            Text("\(subflow.steps.count) stages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(model.workflowCapabilityInstallations) { capability in
                    WorkflowCapabilityInstallationRow(
                        model: model,
                        capability: capability,
                        onTest: testWorkflowCapability
                    )
                }
                HStack {
                    Text("External capabilities run locally without network access and remain disabled until their schema test passes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Install capability…", systemImage: "puzzlepiece.extension") { installWorkflowCapability() }
                }
                if let capabilityImportMessage {
                    Label(capabilityImportMessage, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let recentQualifications = model.snapshot.operations.workflows.qualificationRuns.suffix(12)
                if !recentQualifications.isEmpty {
                    DisclosureGroup("Recent qualification · \(recentQualifications.count)") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(recentQualifications.reversed()) { run in
                                WorkflowQualificationSummaryRow(run: run)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(
                "Component library · \(model.workflowCapabilityInstallations.count + model.snapshot.operations.workflows.connectorInstallations.count + model.snapshot.operations.workflows.rendererInstallations.count + model.snapshot.operations.workflows.subflows.count) installed",
                systemImage: "puzzlepiece.extension"
            )
        }

        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Installed definitions").font(.headline)
                Text("Every revision is immutable; broadened authority remains disabled until reviewed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Create workflow", systemImage: "plus") {
                workflowStudioDraftID = model.createWorkflowStudioDraft(
                    name: "Untitled workflow", summary: "A reusable workflow created in Kaname."
                )
            }
            Button("Install package…", systemImage: "shippingbox") { installWorkflowPackage() }
                .buttonStyle(.borderedProminent)
        }
        if model.workflowDefinitions.isEmpty {
            EmptyPanel(
                symbol: "shippingbox",
                title: "No workflow packages installed",
                detail: "Create an outline in Workflow Studio or install a reviewed package. Definitions never embed credentials or silently inherit connector authority."
            )
        } else {
            ForEach(model.workflowDefinitions) { definition in
                WorkflowDefinitionCard(
                    model: model,
                    definition: definition,
                    googleAccounts: integrations.googleAccounts,
                    runManually: { manualRunDefinition = definition },
                    configureInstallation: { installationToConfigure = $0 },
                    processExistingMatches: { mail.processExistingWorkflowMatches(model: model, binding: $0) }
                )
            }
        }
    }

    @ViewBuilder
    private var simpleRuleList: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Simple rules").font(.headline)
                Text("Narrow Gmail rules remain workflow definitions managed from Automations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New simple rule", systemImage: "plus") { showsRuleSheet = true }
                .buttonStyle(.borderedProminent)
                .disabled(integrations.googleAccounts.isEmpty)
        }
        BoundaryCallout(
            title: "Visible, narrow standing authority",
            detail: "Simple rules bind one Gmail account, one saved query, and one reversible action. Trash and send always require an exact approval."
        )
        if model.snapshot.operations.mailStandingRules.isEmpty {
            EmptyPanel(symbol: "checklist", title: "No simple rules", detail: "Save a narrow archive rule from a tested Gmail query. Rules remain visible and pausable.")
        }
        ForEach(model.snapshot.operations.mailStandingRules) { rule in
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: rule.enabled ? "checkmark.shield.fill" : "pause.circle")
                    .foregroundStyle(rule.enabled ? KanameColor.success : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rule.name).font(.headline)
                    Text(rule.accountIdentity).font(.caption).foregroundStyle(KanameColor.accent)
                    Text(rule.query).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(rule.action.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { rule.enabled },
                    set: { model.setMailStandingRuleEnabled(id: rule.id, enabled: $0) }
                ))
                Button("Run now") { mail.runStandingRule(model: model, rule: rule) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rule.enabled || mail.isBusy)
            }
            .panelStyle()
        }
    }

    private var filteredWorkflowItems: [DesktopWorkflowWorkItemRecord] {
        model.workflowWorkItems.filter { item in
            switch workflowFilter {
            case .needsAttention: item.state.needsAttention
            case .active: !item.state.needsAttention && !item.state.isHistorical
            case .history: item.state.isHistorical
            }
        }
    }

    @ViewBuilder
    private func workflowAssociations(thread: GmailThreadDetailSnapshot) -> some View {
        let items = model.workflowWorkItems(accountID: thread.accountID, conversationID: thread.id)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Text(items.count, format: .number).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } label: {
                    Label("Associated automation", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(KanameColor.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(item.state.label).font(.caption2).foregroundStyle(KanameColor.active)
                        }
                        Spacer()
                        Button("Open in Automations") { openAutomations() }
                            .buttonStyle(.bordered)
                    }
                    .panelStyle()
                }
            }
        }
    }

    private func installWorkflowPackage() {
        do {
            if let message = try DesktopWorkflowTransferUI.installPackage(model: model) {
                workflowImportMessage = message
                workflowCollection = .definitions
            }
        } catch {
            workflowImportMessage = "Installation failed safely: \(error.localizedDescription)"
        }
    }

    private func installWorkflowCapability() {
        guard let store = model.workflowCapabilityStore() else {
            capabilityImportMessage = "Capability storage is unavailable in this workspace."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Install Kaname capability"
        panel.message = "Choose a .kanamecapability directory. Kaname verifies its manifest, executable digest, schemas, paths, and trust receipt before copying it privately."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let inspected = try store.inspectPackage(
                at: url,
                installedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            let alert = NSAlert()
            let permissionSummary = inspected.0.permissions.permissions.map(\.label).joined(separator: ", ")
            alert.messageText = "Install \(inspected.0.name) \(inspected.0.version)?"
            alert.informativeText = "\(inspected.0.summary)\n\nTrust: \(inspected.0.trust.label)\nRuntime: \(inspected.0.runtime.label)\nPermissions: \(permissionSummary.isEmpty ? "Local computation only" : permissionSummary)\n\nThe capability will remain disabled until its local schema test passes."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install disabled")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let receipt = try store.installPackage(
                at: url,
                installedAtUnixMillis: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            guard model.registerWorkflowCapabilityInstallation(receipt) else {
                capabilityImportMessage = "The capability bytes were installed, but Kaname could not commit its receipt."
                return
            }
            let directory = store.installationDirectory(
                capabilityID: receipt.capabilityID, version: receipt.version
            )
            var adapters: [String] = []
            if let connector = try? DesktopWorkflowProcessConnector.loadPackageManifest(from: directory),
               model.registerWorkflowConnector(package: connector, capability: receipt) {
                adapters.append("trusted connector")
            }
            if let renderer = try? DesktopWorkflowRendererAdapter.loadManifest(from: directory),
               model.registerWorkflowRenderer(package: renderer, capability: receipt) {
                adapters.append("renderer")
            }
            let adapterDetail = adapters.isEmpty ? "" : " Registered as " + adapters.joined(separator: " and ") + "."
            capabilityImportMessage = "Installed \(receipt.name) \(receipt.version) disabled.\(adapterDetail) Run its artifact fixture suite before enabling it."
        } catch {
            capabilityImportMessage = "Capability installation failed safely: \(error.localizedDescription)"
        }
    }

    private func testWorkflowCapability(_ capability: DesktopWorkflowCapabilityInstallationRecord) {
        guard let store = model.workflowCapabilityStore() else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose capability qualification suite"
        panel.message = "Choose a fixture directory containing qualification.json plus its declared inputs, artifacts, state, context, expected outputs, and negative cases."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let runs = try DesktopWorkflowCapabilityQualifier().run(
                suiteURL: url, installation: capability, capabilityStore: store,
                scratchRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("KanameWorkflowCapabilityTests", isDirectory: true)
            )
            let passed = !runs.isEmpty && runs.allSatisfy { $0.outcome == .passed }
            runs.forEach { _ = model.recordWorkflowQualification($0) }
            _ = model.recordWorkflowCapabilityTest(id: capability.id, passed: passed)
            let failedAssertions = runs.flatMap(\.assertions).filter { !$0.passed }.count
            capabilityImportMessage = passed
                ? "Qualification passed \(runs.count) fixture\(runs.count == 1 ? "" : "s"). Review bindings and enable \(capability.name) when ready."
                : "Qualification failed with \(failedAssertions) assertion\(failedAssertions == 1 ? "" : "s"); the component remains disabled."
        } catch {
            _ = model.recordWorkflowCapabilityTest(id: capability.id, passed: false)
            capabilityImportMessage = "Test failed; the capability remains disabled: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var actionReview: some View {
        if let action = activeAction {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Action preview", systemImage: "checkmark.shield").font(.headline)
                    Spacer()
                    KanameStatusBadge(
                        KanameDesktopStatusPresentation.action(action.state),
                        density: .compact
                    )
                }
                Text(action.preview)
                Text(action.exactTarget).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if let draftID = pendingOutboundDraftID,
                   let draft = model.snapshot.domains.emailDrafts.first(where: { $0.id == draftID }) {
                    DisclosureGroup("Resolved message body") { Text(draft.body).textSelection(.enabled).padding(.top, 6) }
                }
                HStack {
                    if action.standingRuleID != nil {
                        Button("Run under standing rule") { executeActive(action: action) }.buttonStyle(.borderedProminent)
                    } else if activeApproval == nil {
                        Button("Request approval") { mail.requestActiveApproval(model: model) }.buttonStyle(.borderedProminent)
                    } else if activeApproval?.state == .approved {
                        Button(action.kind == .send ? "Send approved message" : "Apply approved action") { executeActive(action: action) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Label(activeApproval?.state == .rejected ? "Rejected" : "Waiting in Inbox", systemImage: "tray.full")
                    }
                }
            }
            .panelStyle()
        }
    }

    @ViewBuilder
    private var mailStatus: some View {
        if !mail.failedAccounts.isEmpty {
            BoundaryCallout(title: "Partial Gmail refresh", detail: "Other accounts remain usable. Reconnect: \(mail.failedAccounts.joined(separator: ", ")).")
        }
        if let message = mail.message { BoundaryCallout(title: "Mail status", detail: message) }
    }

    private func executeActive(action: DesktopMailActionRecord) {
        if let mutation = pendingMutation {
            mail.executeActiveThreadMutation(model: model, mutation: mutation)
        } else if let draftID = pendingOutboundDraftID,
                  let draft = model.snapshot.domains.emailDrafts.first(where: { $0.id == draftID }) {
            mail.executeOutbound(model: model, draft: draft, send: pendingOutboundSend)
        }
    }

    private func googleAccount(for draft: DesktopEmailDraft) -> NativeGoogleAccountSnapshot? {
        guard let localID = draft.accountID,
              let identity = accounts.first(where: { $0.id == localID })?.identity else { return nil }
        return integrations.googleAccounts.first { $0.identity == identity }
    }

    private func replySeed(for thread: GmailThreadDetailSnapshot) -> MailReplySeed? {
        guard let message = thread.messages.last,
              let localAccountID = accounts.first(where: { $0.identity == thread.accountIdentity })?.id else { return nil }
        let subject = message.subject.lowercased().hasPrefix("re:") ? message.subject : "Re: \(message.subject)"
        return MailReplySeed(accountID: localAccountID, recipients: message.sender, subject: subject)
    }
}

private enum MailSection: String, CaseIterable {
    case inbox
    case drafts

    var label: String { rawValue.capitalized }
}

private enum MailWorkflowCollection: String, CaseIterable {
    case work
    case definitions
    case simpleRules

    var label: String {
        switch self {
        case .work: "Work"
        case .definitions: "Definitions"
        case .simpleRules: "Simple rules"
        }
    }
}

private enum MailWorkflowFilter: String, CaseIterable {
    case needsAttention
    case active
    case history

    var label: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .active: "Active"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .needsAttention: "checkmark.circle"
        case .active: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }

    var emptyTitle: String {
        switch self {
        case .needsAttention: "Nothing needs attention"
        case .active: "No active workflow work"
        case .history: "No workflow history"
        }
    }
}

private struct MailReplySeed: Identifiable {
    let id = UUID()
    let accountID: String
    let recipients: String
    let subject: String
}

private struct MailThreadRow: View {
    let thread: GmailThreadDetailSnapshot

    var body: some View {
        let last = thread.messages.last
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(last?.sender ?? "Unknown sender").font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if thread.labels.contains("UNREAD") { Circle().fill(KanameColor.active).frame(width: 7, height: 7) }
            }
            Text(subject(last)).font(.subheadline).lineLimit(1)
            Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(thread.accountIdentity).font(.caption2).foregroundStyle(KanameColor.accent)
        }
        .padding(.vertical, 5)
    }

    private func subject(_ message: GmailMessageSnapshot?) -> String {
        guard let subject = message?.subject, !subject.isEmpty else { return "(No subject)" }
        return subject
    }
}

private struct MailReaderBody: View {
    let message: GmailMessageSnapshot
    @State private var presentation: Presentation = .formatted
    @State private var loadsRemoteImagesDirectly = false

    private enum Presentation: String, CaseIterable, Identifiable {
        case formatted = "Formatted"
        case plainText = "Plain text"

        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = message.bodyDisplayNotice, !notice.isEmpty {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sanitizedHTML = message.sanitizedHTML, !sanitizedHTML.isEmpty {
                HStack(spacing: 10) {
                    Picker("Message view", selection: $presentation) {
                        ForEach(Presentation.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()

                    Spacer()

                    Label(
                        loadsRemoteImagesDirectly ? "Direct images" : "Safe HTML",
                        systemImage: loadsRemoteImagesDirectly
                            ? "exclamationmark.shield.fill"
                            : "shield.lefthalf.filled"
                    )
                        .font(.caption2)
                        .foregroundStyle(loadsRemoteImagesDirectly ? KanameColor.warning : .secondary)
                        .help(loadsRemoteImagesDirectly
                            ? directImageHelp
                            : "Scripts, forms, remote images, and other remote content are blocked.")
                }

                remoteImageControls

                switch presentation {
                case .formatted:
                    MailHTMLMessageView(
                        html: loadsRemoteImagesDirectly
                            ? (message.directRemoteImagesHTML ?? sanitizedHTML)
                            : sanitizedHTML,
                        loadsRemoteImagesDirectly: loadsRemoteImagesDirectly
                    )
                case .plainText:
                    plainText
                }
            } else {
                plainText
            }
        }
        .onChange(of: message.id) { _, _ in
            loadsRemoteImagesDirectly = false
        }
    }

    @ViewBuilder
    private var remoteImageControls: some View {
        if message.embeddedImageCount > 0 {
            Label(
                "\(message.embeddedImageCount) embedded image\(message.embeddedImageCount == 1 ? "" : "s") loaded locally",
                systemImage: "photo.on.rectangle.angled"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("These images came from this email's validated MIME attachments. Kaname did not contact the sender to display them.")
        }

        if message.remoteImageCount > 0, message.directRemoteImagesHTML != nil {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 12) {
                    Toggle(directImageToggleTitle, isOn: $loadsRemoteImagesDirectly)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Label("Privacy relay · Coming soon", systemImage: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("A privacy relay is planned but is not configured. Direct image loading is not private.")
                }

                Label(
                    remoteImageStatusText,
                    systemImage: loadsRemoteImagesDirectly ? "exclamationmark.triangle.fill" : "eye.slash"
                )
                .font(.caption2)
                .foregroundStyle(loadsRemoteImagesDirectly ? KanameColor.warning : .secondary)
            }
        }
    }

    private var directImageToggleTitle: String {
        guard message.insecureRemoteImageCount > 0 else {
            return "Load remote images directly"
        }
        return message.insecureRemoteImageCount == message.remoteImageCount
            ? "Try images over HTTPS"
            : "Load remote images (HTTPS only)"
    }

    private var directImageHelp: String {
        let base = "Remote images are loading directly from their senders. Scripts, forms, and other remote content remain blocked."
        guard message.insecureRemoteImageCount > 0 else { return base }
        return "\(base) Kaname rewrote insecure HTTP image URLs to HTTPS and never requested them over plaintext HTTP."
    }

    private var remoteImageStatusText: String {
        let remoteCount = message.remoteImageCount
        let insecureCount = message.insecureRemoteImageCount
        if loadsRemoteImagesDirectly {
            let warning = "The sender may observe this request, your network address, and when this message was opened."
            guard insecureCount > 0 else { return warning }
            return "\(warning) Kaname rewrote \(imageCount(insecureCount)) from HTTP to HTTPS."
        }
        guard insecureCount > 0 else {
            return "\(remoteCount) remote image\(remoteCount == 1 ? " is" : "s are") blocked to prevent tracking."
        }
        if insecureCount == remoteCount {
            return "\(imageCount(insecureCount)) \(insecureCount == 1 ? "uses" : "use") insecure HTTP and \(insecureCount == 1 ? "is" : "are") blocked. Loading will try HTTPS instead."
        }
        return "\(remoteCount) remote images are blocked to prevent tracking. Of those, \(imageCount(insecureCount)) \(insecureCount == 1 ? "uses" : "use") insecure HTTP and will be tried over HTTPS."
    }

    private func imageCount(_ count: Int) -> String {
        "\(count) image\(count == 1 ? "" : "s")"
    }

    private var plainText: some View {
        Text(message.body.isEmpty ? "No readable text body." : message.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
