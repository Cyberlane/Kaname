import AppKit
import Darwin
import KanameDesignSystem
import SwiftUI

private func catalogArgument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private struct CatalogCaptureConfiguration {
    let width: CGFloat
    let height: CGFloat
    let colorScheme: ColorScheme
    let increasedContrast: Bool
    let differentiateWithoutColor: Bool
    let reduceMotion: Bool
    let dynamicTypeSize: DynamicTypeSize
    let locale: Locale
    let activeWindow: Bool

    static let commandLine: Self = {
        let viewport = catalogArgument("--viewport") ?? "1280x860"
        let dimensions = viewport.split(separator: "x", maxSplits: 1).compactMap { Double($0) }
        let appearance = catalogArgument("--appearance") ?? "dark"
        let textScale = catalogArgument("--text-scale") ?? "standard"
        return Self(
            width: dimensions.count == 2 ? CGFloat(dimensions[0]) : 1_280,
            height: dimensions.count == 2 ? CGFloat(dimensions[1]) : 860,
            colorScheme: appearance == "light" ? ColorScheme.light : ColorScheme.dark,
            increasedContrast: appearance == "highContrast",
            differentiateWithoutColor: boolArgument("--differentiate-without-color"),
            reduceMotion: boolArgument("--reduce-motion"),
            dynamicTypeSize: textScale == "accessibility3" ? DynamicTypeSize.accessibility3 : DynamicTypeSize.large,
            locale: Locale(identifier: catalogArgument("--locale") ?? "en_US"),
            activeWindow: boolArgument("--active-window", defaultValue: true)
        )
    }()

    private static func boolArgument(_ name: String, defaultValue: Bool = false) -> Bool {
        guard let value = catalogArgument(name) else { return defaultValue }
        return value == "true" || value == "1"
    }
}

private extension View {
    func catalogEnvironment(_ configuration: CatalogCaptureConfiguration) -> some View {
        preferredColorScheme(configuration.colorScheme)
            .environment(\.colorScheme, configuration.colorScheme)
            .environment(
                \.kanameAccessibilityPreferences,
                KanameAccessibilityPreferences(
                    differentiateWithoutColor: configuration.differentiateWithoutColor,
                    reduceMotion: configuration.reduceMotion,
                    increasedContrast: configuration.increasedContrast
                )
            )
            .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
            .environment(\.locale, configuration.locale)
            .environment(\.controlActiveState, configuration.activeWindow ? .key : .inactive)
    }
}

private struct CatalogTitleDetail: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(KanameColor.textSecondary)
        }
    }
}

@main
private enum KanameDesignCatalogMain {
    @MainActor
    static func main() {
        guard let snapshotPath = catalogArgument("--snapshot") else {
            KanameDesignCatalogApp.main()
            return
        }
        guard snapshotPath.hasPrefix("/"), snapshotPath != "/" else {
            fputs("Kaname Design Catalog requires an absolute snapshot path.\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
        do {
            try renderSnapshot(at: snapshotPath)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("Kaname Design Catalog snapshot failed: \(error)\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func renderSnapshot(at path: String) throws {
        let configuration = CatalogCaptureConfiguration.commandLine
        let content = KanameDesignCatalogRoot(
            initialPage: CatalogPage.commandLinePage,
            snapshotMode: true
        )
            .frame(width: configuration.width, height: configuration.height, alignment: .topLeading)
            .clipped()
            .catalogEnvironment(configuration)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        fputs(
            "Rendered offscreen Kaname Design Catalog snapshot \(Int(configuration.width))x\(Int(configuration.height)) points.\n",
            stderr
        )
    }
}

private struct KanameDesignCatalogApp: App {
    private let captureConfiguration = CatalogCaptureConfiguration.commandLine

    var body: some Scene {
        Window("Kaname Design Catalog", id: "catalog") {
            KanameDesignCatalogRoot(initialPage: CatalogPage.commandLinePage)
                .catalogEnvironment(captureConfiguration)
        }
        .defaultSize(width: captureConfiguration.width, height: captureConfiguration.height)
    }
}

private enum CatalogPage: String, CaseIterable, Identifiable {
    case overview
    case foundations
    case components
    case desktop
    case ios
    case link
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .foundations: "Foundations"
        case .components: "Components"
        case .desktop: "Kaname Desktop"
        case .ios: "Kaname iOS"
        case .link: "Kaname Link"
        case .accessibility: "Accessibility"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "rectangle.3.group.fill"
        case .foundations: "paintpalette.fill"
        case .components: "square.grid.3x3.fill"
        case .desktop: "macwindow"
        case .ios: "iphone"
        case .link: "link.circle.fill"
        case .accessibility: "accessibility.fill"
        }
    }

    var evidenceLabel: String {
        switch self {
        case .overview, .foundations, .components:
            "Implemented foundation"
        case .desktop, .ios, .link:
            "Catalog projection"
        case .accessibility:
            "Qualification matrix"
        }
    }

    var evidenceTone: KanameStatusTone {
        switch self {
        case .overview, .foundations, .components: .success
        case .desktop, .ios, .link: .informational
        case .accessibility: .attention
        }
    }

    static var commandLinePage: CatalogPage {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--page"),
              arguments.indices.contains(index + 1),
              let page = CatalogPage(rawValue: arguments[index + 1]) else { return .overview }
        return page
    }
}

private struct KanameDesignCatalogRoot: View {
    @State private var selectedPage: CatalogPage
    private let snapshotMode: Bool

    init(initialPage: CatalogPage, snapshotMode: Bool = false) {
        _selectedPage = State(initialValue: initialPage)
        self.snapshotMode = snapshotMode
    }

    var body: some View {
        VStack(spacing: 0) {
            KanameSyntheticDataBanner()
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: KanameSpacing.large) {
                    VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                        Label("Kaname", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.title2.bold())
                            .foregroundStyle(KanameColor.textPrimary)
                        Text("Design System \(KanameDesignSystemMetadata.version)")
                            .font(.caption)
                            .foregroundStyle(KanameColor.textSecondary)
                    }
                    .padding(.horizontal, KanameSpacing.large)
                    .padding(.top, KanameSpacing.large)

                    catalogNavigation

                    KanameAuthorityBoundaryCard(
                        title: "Catalog boundary",
                        detail: "No providers, credentials, private state, processes, or network services are initialized."
                    )
                    .padding(KanameSpacing.large)
                }
                .background(KanameColor.sidebar)
                .frame(width: 240)

                Rectangle()
                    .fill(KanameColor.separator)
                    .frame(width: 1)

                CatalogPageView(page: selectedPage, snapshotMode: snapshotMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(KanameColor.textPrimary)
        .background(KanameColor.canvas)
        .tint(KanameColor.accent)
    }

    @ViewBuilder
    private var catalogNavigation: some View {
        if snapshotMode {
            catalogNavigationItems
        } else {
            ScrollView {
                catalogNavigationItems
            }
        }
    }

    private var catalogNavigationItems: some View {
        VStack(spacing: KanameSpacing.xSmall) {
            ForEach(CatalogPage.allCases) { page in
                Button {
                    selectedPage = page
                } label: {
                    HStack {
                        Label(page.title, systemImage: page.symbolName)
                        Spacer()
                    }
                    .padding(.horizontal, KanameSpacing.small)
                    .padding(.vertical, 7)
                    .background(
                        selectedPage == page ? KanameColor.selected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, KanameSpacing.small)
    }
}

private struct CatalogPageView: View {
    let page: CatalogPage
    let snapshotMode: Bool

    @ViewBuilder
    var body: some View {
        if snapshotMode {
            pageStack
        } else {
            ScrollView {
                pageStack
            }
        }
    }

    private var pageStack: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.xxLarge) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: KanameSpacing.xSmall) {
                    Text(page.title).font(KanameTypography.display)
                    Text(subtitle)
                        .font(KanameTypography.supporting)
                        .foregroundStyle(KanameColor.textSecondary)
                }
                Spacer()
                KanameStatusBadge(page.evidenceLabel, tone: page.evidenceTone)
                KanameStatusBadge("Synthetic-public", tone: .external)
            }

            pageContent
            Spacer(minLength: 0)
        }
        .padding(KanameSpacing.xxxLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KanameColor.canvas)
    }

    private var subtitle: String {
        switch page {
        case .overview: "One semantic language, rendered with native controls on every platform."
        case .foundations: "Purposeful color, type, spacing, radius, sizing, and motion roles."
        case .components: "Reusable primitives with explicit state and accessibility meaning."
        case .desktop: "Dense, resizable, keyboard-first control-plane patterns for macOS."
        case .ios: "Touch-first remote control that preserves the five-hub information architecture."
        case .link: "Native external collaboration with a visibly constrained authority boundary."
        case .accessibility: "Color-independent meaning, adaptable text, focus, contrast, and reduced motion."
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .overview: CatalogOverview()
        case .foundations: CatalogFoundations()
        case .components: CatalogComponents()
        case .desktop: CatalogDesktop()
        case .ios: CatalogIOS()
        case .link: CatalogLink()
        case .accessibility: CatalogAccessibility()
        }
    }
}

private struct CatalogApprovalExample: View {
    let title: String
    let impact: String
    let boundary: String

    @State private var state = KanameApprovalState.proposed

    var body: some View {
        KanameApprovalCard(
            title: title,
            impact: impact,
            boundary: boundary,
            state: state,
            onRequestChanges: { state = .changesRequested },
            onReject: { state = .rejected },
            onApprove: { state = .approved }
        )
    }
}

private struct CatalogOverview: View {
    private let principles = [
        ("Native first", "SwiftUI, AppKit, WinUI, and GTK keep their platform interaction mechanics.", "macwindow"),
        ("Authority visible", "Proposed, local, external, accepted, and verified are never visually conflated.", "checkmark.shield.fill"),
        ("Status is language", "Every status combines a stable term, symbol, and semantic color role.", "waveform.path.ecg"),
        ("Evidence over theater", "Receipts state exactly what was observed, without implying external acceptance.", "doc.text.magnifyingglass"),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: KanameSpacing.large) {
            ForEach(principles, id: \.0) { item in
                KanameSurface {
                    HStack(alignment: .top, spacing: KanameSpacing.medium) {
                        Image(systemName: item.2)
                            .font(.title2)
                            .foregroundStyle(KanameColor.accent)
                            .frame(width: 30)
                        CatalogTitleDetail(title: item.0, detail: item.1)
                        Spacer()
                    }
                }
            }
        }

        KanameSectionHeader("Product surfaces", detail: "Shared semantics; platform-native structure and density")
        HStack(spacing: KanameSpacing.large) {
            KanameMetricCard("Desktop", value: "16", detail: "Link-branch destinations", tone: .informational)
            KanameMetricCard("iOS", value: "5", detail: "Persistent hubs", tone: .active)
            KanameMetricCard("Link", value: "4", detail: "Host + native client families", tone: .external)
            KanameMetricCard("Privacy", value: "100%", detail: "Synthetic catalog data", tone: .success)
        }

        CatalogApprovalExample(
            title: "Apply approved implementation plan",
            impact: "Creates an isolated task worktree and allows bounded source changes only within the approved scope.",
            boundary: "Commit, push, pull request, merge, release, and external delivery remain separate actions."
        )
    }
}

private struct CatalogFoundations: View {
    private let colors: [(String, Color, String)] = [
        ("Canvas", KanameColor.canvas, "KanameColor.canvas"),
        ("Sidebar", KanameColor.sidebar, "KanameColor.sidebar"),
        ("Surface", KanameColor.surface, "KanameColor.surface"),
        ("Raised", KanameColor.raised, "KanameColor.raised"),
        ("Selected", KanameColor.selected, "KanameColor.selected"),
        ("Accent", KanameColor.accent, "KanameColor.accent"),
        ("Success", KanameColor.success, "KanameColor.success"),
        ("Warning", KanameColor.warning, "KanameColor.warning"),
        ("Danger", KanameColor.danger, "KanameColor.danger"),
        ("External", KanameColor.external, "KanameColor.external"),
    ]

    var body: some View {
        KanameSectionHeader("Semantic color", detail: "Feature code names purpose, not palette")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: KanameSpacing.medium) {
            ForEach(colors, id: \.0) { item in
                VStack(alignment: .leading, spacing: KanameSpacing.small) {
                    RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                        .fill(item.1)
                        .frame(height: 68)
                        .overlay {
                            RoundedRectangle(cornerRadius: KanameRadius.control, style: .continuous)
                                .stroke(KanameColor.separator, lineWidth: 1)
                        }
                    Text(item.0).font(.caption.weight(.semibold))
                    Text(item.2).font(KanameTypography.technical).foregroundStyle(KanameColor.textSecondary)
                }
            }
        }

        HStack(alignment: .top, spacing: KanameSpacing.large) {
            KanameSurface {
                VStack(alignment: .leading, spacing: KanameSpacing.medium) {
                    KanameSectionHeader("Typography")
                    Text("Display title").font(KanameTypography.display)
                    Text("Screen title").font(KanameTypography.screenTitle)
                    Text("Section title").font(KanameTypography.sectionTitle)
                    Text("Readable body copy explains the current state.").font(KanameTypography.body)
                    Text("Metadata · 12:42 JST").font(KanameTypography.metadata).foregroundStyle(KanameColor.textSecondary)
                    Text("receipt: localStored").font(KanameTypography.technical).foregroundStyle(KanameColor.accent)
                }
            }
            .frame(maxWidth: .infinity)

            KanameSurface {
                VStack(alignment: .leading, spacing: KanameSpacing.medium) {
                    KanameSectionHeader("Spacing and radius")
                    ForEach([2, 4, 8, 12, 16, 20, 24, 32, 40], id: \.self) { value in
                        HStack {
                            Text("\(value)").font(KanameTypography.technical).frame(width: 28, alignment: .trailing)
                            RoundedRectangle(cornerRadius: 2).fill(KanameColor.accent).frame(width: CGFloat(value * 3), height: 6)
                        }
                    }
                    HStack {
                        radiusSample("Control", KanameRadius.control)
                        radiusSample("Card", KanameRadius.card)
                        radiusSample("Panel", KanameRadius.panel)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func radiusSample(_ name: String, _ radius: CGFloat) -> some View {
        VStack {
            RoundedRectangle(cornerRadius: radius).fill(KanameColor.selected).frame(width: 74, height: 46)
            Text(name).font(.caption2)
        }
    }
}

private struct CatalogComponents: View {
    var body: some View {
        KanameSectionHeader("Status badges", detail: "Symbols and text preserve meaning without color")
        KanameSurface {
            HStack(spacing: KanameSpacing.small) {
                ForEach(KanameStatusTone.allCases, id: \.self) { tone in
                    KanameStatusBadge(tone.rawValue.capitalized, tone: tone)
                }
            }
        }

        KanameSectionHeader("Calls to attention")
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: KanameSpacing.medium) {
            KanameCallout("Provider unavailable", message: "The run remains queued. No provider work has started.", tone: .warning)
            KanameCallout("Staged evidence example", message: "A synthetic receipt represents local tests passing for one exact staged snapshot.", tone: .success)
            KanameCallout("External content", message: "Treat collaborator text as untrusted input, never as tool authority.", tone: .external)
            KanameCallout("Outcome uncertain", message: "No confirmed remote outcome was observed. Reconcile before retrying.", tone: .warning)
        }

        HStack(alignment: .top, spacing: KanameSpacing.large) {
            CatalogApprovalExample(
                title: "Send prepared message",
                impact: "The proposed recipient and body would leave this Mac through the selected account.",
                boundary: "Save as a draft or reject without contacting the recipient."
            )
            KanameSurface {
                KanameEmptyState(
                    "No evidence yet",
                    message: "Run the approved checks to attach source, test, and runtime evidence.",
                    symbolName: "doc.badge.magnifyingglass"
                )
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CatalogDesktop: View {
    var body: some View {
        KanameSectionHeader("Four-region workspace", detail: "Sidebar, collection, primary detail, and optional inspector resize independently")
        HStack(spacing: 1) {
            desktopSidebar
            desktopCollection
            desktopDetail
            desktopInspector
        }
        .frame(height: 560)
        .background(KanameColor.separator)
        .clipShape(RoundedRectangle(cornerRadius: KanameRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: KanameRadius.panel, style: .continuous)
                .stroke(KanameColor.separator, lineWidth: 1)
        }
    }

    private var desktopSidebar: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.small) {
            Label("Kaname", systemImage: "point.3.connected.trianglepath.dotted").font(.headline).padding(.bottom, 8)
            ForEach(["Home", "Threads", "Inbox", "Projects", "Research", "Obsidian", "Email", "Calendar", "Automations", "GitHub", "Coding", "Kaname Link"], id: \.self) { item in
                HStack {
                    Image(systemName: item == "Threads" ? "bubble.left.and.bubble.right.fill" : "circle.grid.2x2")
                    Text(item)
                    Spacer()
                    if item == "Inbox" { Text("3").font(.caption2).padding(4).background(KanameColor.warning.opacity(0.2), in: Capsule()) }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(item == "Threads" ? KanameColor.selected : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer()
            KanameStatusBadge("Mac authority host", tone: .informational)
        }
        .padding(KanameSpacing.large)
        .frame(width: 170)
        .background(KanameColor.sidebar)
    }

    private var desktopCollection: some View {
        VStack(alignment: .leading, spacing: 0) {
            KanameSectionHeader("Threads", detail: "Active and awaiting you") {
                Button("New") {}
                    .disabled(true)
            }
            .padding(KanameSpacing.large)
            Divider()
            ForEach([("Design system", "Needs review"), ("Release qualification", "Running"), ("Mail triage", "Completed")], id: \.0) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.0).font(.subheadline.weight(.semibold))
                    Text(item.1).font(.caption).foregroundStyle(item.1 == "Needs review" ? KanameColor.warning : KanameColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(item.0 == "Design system" ? KanameColor.selected : Color.clear)
                Divider()
            }
            Spacer()
        }
        .frame(width: 190)
        .background(KanameColor.surface)
    }

    private var desktopDetail: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Design system").font(.headline)
                    Text("Discuss → Plan → Approve → Implement").font(.caption).foregroundStyle(KanameColor.textSecondary)
                }
                Spacer()
                KanameStatusBadge("Plan ready", tone: .attention)
            }
            .padding(KanameSpacing.large)
            Divider()
            VStack(spacing: KanameSpacing.medium) {
                KanameMessageBubble(
                    author: "Justin",
                    body: "Document every product surface and create one complete design system.",
                    role: .user,
                    receipt: KanameMessageReceipt(state: .localStored)
                )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                KanameMessageBubble(
                    author: "Kaname",
                    body: "The plan covers Desktop, iOS, Link, documentation, and synthetic screenshots.",
                    role: .assistant,
                    receipt: KanameMessageReceipt(state: .localStored)
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                CatalogApprovalExample(
                    title: "Approve exact plan",
                    impact: "Unlocks only the listed implementation scope.",
                    boundary: "External writes and release operations remain separately controlled."
                )
                Spacer(minLength: 0)
            }
            .padding(KanameSpacing.large)
            HStack {
                Text("Synthetic preview · reply disabled").foregroundStyle(KanameColor.textTertiary)
                Spacer()
                Button("Send") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
            }
            .padding(KanameSpacing.medium)
            .background(KanameColor.sidebar)
        }
        .frame(minWidth: 330, maxWidth: .infinity)
        .background(KanameColor.canvas)
    }

    private var desktopInspector: some View {
        VStack(alignment: .leading, spacing: KanameSpacing.large) {
            KanameSectionHeader("Context")
            KanameStatusBadge("Synthetic fixture", tone: .external)
            Label("Task worktree", systemImage: "arrow.triangle.branch")
            Text("kaname/task/design-system-atlas").font(KanameTypography.technical).foregroundStyle(KanameColor.textSecondary)
            Divider()
            KanameSectionHeader("Evidence")
            Label("Source mapped", systemImage: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
            Label("Tests pending", systemImage: "clock.fill").foregroundStyle(KanameColor.warning)
            Spacer()
        }
        .font(.caption)
        .padding(KanameSpacing.large)
        .frame(width: 150)
        .background(KanameColor.surface)
    }
}

private struct CatalogIOS: View {
    var body: some View {
        HStack(alignment: .top, spacing: KanameSpacing.xxxLarge) {
            VStack(spacing: 0) {
                HStack {
                    Text("9:41").font(.caption.bold())
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                VStack(alignment: .leading, spacing: KanameSpacing.large) {
                    Text("Home").font(.system(size: 27, weight: .bold, design: .rounded))
                    KanameCallout("Mac reachable", message: "Commands remain approval-bound on the host.", tone: .success)
                    HStack {
                        KanameMetricCard("Attention", value: "3", detail: "Items", tone: .attention)
                        KanameMetricCard("Runs", value: "2", detail: "Active", tone: .active)
                    }
                    KanameSectionHeader("Continue")
                    mobileRow("Design system", "Plan ready for review", .attention)
                    mobileRow("Release qualification", "2 checks running", .active)
                    Spacer()
                }
                .padding(16)
                HStack {
                    mobileTab("Home", "house.fill", true)
                    mobileTab("Work", "bubble.left.and.bubble.right", false)
                    mobileTab("Projects", "folder", false)
                    mobileTab("Operate", "bolt", false)
                    mobileTab("Library", "books.vertical", false)
                }
                .padding(.vertical, 10)
                .background(KanameColor.sidebar)
            }
            .frame(width: 360, height: 660)
            .background(KanameColor.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 42).stroke(Color.black, lineWidth: 8) }

            VStack(alignment: .leading, spacing: KanameSpacing.large) {
                KanameSectionHeader("iPhone contract", detail: "Touch-first remote; the Mac remains the authority host")
                KanameCallout("Five stable hubs", message: "Home, Work, Projects, Operate, and Library remain persistent destinations.", tone: .informational)
                KanameCallout("44-point helper", message: "Available for product adoption; screen-level touch-target qualification remains pending.", tone: .warning)
                KanameCallout("Honest projections", message: "Fixture-backed domain cards are not documented as live-synced until proven.", tone: .warning)
                KanameCallout("Private notifications", message: "Push notifications contain only a safe prompt to open Kaname.", tone: .informational)
            }
            .frame(maxWidth: 520)
        }
    }

    private func mobileRow(_ title: String, _ detail: String, _ tone: KanameStatusTone) -> some View {
        KanameSurface(padding: 12) {
            HStack {
                Image(systemName: tone.symbolName).foregroundStyle(tone.color)
                VStack(alignment: .leading) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(KanameColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(KanameColor.textTertiary)
            }
        }
    }

    private func mobileTab(_ label: String, _ symbol: String, _ selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
            Text(label).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(selected ? KanameColor.accent : KanameColor.textSecondary)
        .frame(maxWidth: .infinity)
    }
}

private struct CatalogLink: View {
    var body: some View {
        KanameAuthorityBoundaryCard(
            title: "External principals are never trusted devices",
            detail: "Link exposes only explicitly shared messages and publications. It grants no tools, files, model, host, or approval authority."
        )

        HStack(spacing: 1) {
            VStack(alignment: .leading, spacing: KanameSpacing.large) {
                Label("Kaname Link", systemImage: "link.circle.fill").font(.title2.bold())
                Text("External collaboration").foregroundStyle(KanameColor.textSecondary)
                KanameStatusBadge("Verified host", tone: .success)
                Text("LINK SPACES").font(.caption.bold()).foregroundStyle(KanameColor.textSecondary)
                KanameSurface(padding: 12) {
                    VStack(alignment: .leading) {
                        Text("Product review").font(.subheadline.weight(.semibold))
                        Text("Host-verified").font(.caption).foregroundStyle(KanameColor.success)
                    }
                }
                Spacer()
                KanameAuthorityBoundaryCard(title: "Restricted", detail: "No control of Kaname, tools, files, models, or the host computer.")
            }
            .padding(20)
            .frame(width: 260)
            .background(KanameColor.sidebar)

            VStack(alignment: .leading, spacing: 0) {
                Text("Product review").font(.title2.bold()).padding(20)
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Design system proposal").fontWeight(.semibold)
                    KanameStatusBadge("Waiting for you", tone: .attention)
                }
                .padding(16)
                .background(KanameColor.selected)
                Spacer()
            }
            .frame(width: 310)
            .background(KanameColor.surface)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Design system proposal").font(.title2.bold())
                        Text("Deliberately shared by the host").font(.caption).foregroundStyle(KanameColor.textSecondary)
                    }
                    Spacer()
                    KanameStatusBadge("Response actions pending", tone: .neutral)
                }
                .padding(20)
                Divider()
                VStack(spacing: 16) {
                    KanameMessageBubble(
                        author: "Kaname host",
                        body: "Please review the shared visual direction and authority language.",
                        role: .host,
                        receipt: KanameMessageReceipt(state: .published)
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KanameMessageBubble(
                        author: "External reviewer",
                        body: "The boundary is clear. Please increase the warning contrast.",
                        role: .collaborator,
                        receipt: KanameMessageReceipt(state: .gatewayAccepted)
                    )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Spacer()
                }
                .padding(24)
                HStack {
                    Text("Synthetic preview · messaging disabled").foregroundStyle(KanameColor.textTertiary)
                    Spacer()
                    KanameStatusBadge("Send disabled", tone: .neutral)
                }
                .padding(18)
                .background(KanameColor.sidebar)
            }
            .frame(maxWidth: .infinity)
            .background(KanameColor.canvas)
        }
        .frame(height: 510)
        .background(KanameColor.separator)
        .clipShape(RoundedRectangle(cornerRadius: KanameRadius.panel, style: .continuous))
    }
}

private struct CatalogAccessibility: View {
    private let checks = [
        ("Differentiate without color", "Shared status badges combine stable labels and symbols with color.", "eye.trianglebadge.exclamationmark", "Implemented baseline", KanameStatusTone.success),
        ("Increased contrast", "Windows resources exist; Apple and GTK behavior still needs implementation and proof.", "circle.lefthalf.filled", "Qualification pending", KanameStatusTone.warning),
        ("Reduced motion", "Motion guidance exists; product-level Reduce Motion adoption remains pending.", "figure.walk.motion", "Adoption pending", KanameStatusTone.warning),
        ("Dynamic Type", "Shared components use semantic styles; complete screen reflow is not yet qualified.", "textformat.size.larger", "Qualification pending", KanameStatusTone.warning),
        ("Keyboard and focus", "Native controls preserve a baseline; traversal and Escape need screen-level review.", "keyboard", "Manual proof pending", KanameStatusTone.attention),
        ("Touch targets", "A 44-point mobile helper exists; feature-level adoption is still tracked.", "hand.tap.fill", "Adoption pending", KanameStatusTone.warning),
        ("Platform assistive tech", "VoiceOver, Narrator, and Orca checks must run on their target platforms.", "waveform", "Target proof pending", KanameStatusTone.blocked),
        ("Privacy", "Catalog fixtures are synthetic-public and initialize no private provider or account state.", "lock.shield.fill", "Implemented", KanameStatusTone.success),
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: KanameSpacing.large) {
            ForEach(checks, id: \.0) { check in
                KanameSurface {
                    HStack(alignment: .top, spacing: KanameSpacing.medium) {
                        Image(systemName: check.2)
                            .font(.title2)
                            .foregroundStyle(KanameColor.accent)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        CatalogTitleDetail(title: check.0, detail: check.1)
                        Spacer()
                        KanameStatusBadge(check.3, tone: check.4)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }

        KanameSectionHeader("Non-color state proof")
        KanameSurface {
            HStack(spacing: KanameSpacing.medium) {
                KanameStatusBadge("Queued", tone: .informational)
                KanameStatusBadge("Running", tone: .active)
                KanameStatusBadge("Needs review", tone: .attention)
                KanameStatusBadge("Completed", tone: .success)
                KanameStatusBadge("Interrupted", tone: .blocked)
                KanameStatusBadge("Failed", tone: .danger)
                KanameStatusBadge("External", tone: .external)
            }
        }
    }
}
