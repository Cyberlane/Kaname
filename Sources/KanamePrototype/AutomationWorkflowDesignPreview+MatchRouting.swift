import KanameDesktop
import KanameLocalCore
import KanameProtocol
import KanamePrototypeUI
import KanameWorkflowHost
import SwiftUI
import KanameDesignSystem

private enum AutomationMatchDesignOption: String, CaseIterable, Identifiable {
    case namedPorts = "Named ports"
    case expandedBoard = "Expanded board"
    case objectConditions = "Object rules"
    case errorRecovery = "Error + retry"

    var id: String { rawValue }

    init(arguments: [String]) {
        if arguments.contains("--desktop-automation-builder-match-board") { self = .expandedBoard }
        else if arguments.contains("--desktop-automation-builder-match-object") { self = .objectConditions }
        else if arguments.contains("--desktop-automation-builder-match-error") { self = .errorRecovery }
        else { self = .namedPorts }
    }

    var title: String {
        switch self {
        case .namedPorts: "Option A · Compact Match with named ports"
        case .expandedBoard: "Option B · Expand Match into a switchboard"
        case .objectConditions: "Option C · Match a whole object with compound conditions"
        case .errorRecovery: "Required scenario · Match an error into retry or recovery"
        }
    }

    var summary: String {
        switch self {
        case .namedPorts: "Best for a small, typed set of cases that should remain visible on the canvas"
        case .expandedBoard: "Keeps many cases readable without turning every workflow node into a very tall card"
        case .objectConditions: "Each output arm can combine nested fields with ALL, ANY, and NOT groups"
        case .errorRecovery: "Routes a typed error while keeping retry policy and unknown outcomes explicit"
        }
    }
}

struct AutomationMatchRoutingDesignPreview: View {
    @State private var option: AutomationMatchDesignOption

    init() {
        _option = State(initialValue: AutomationMatchDesignOption(arguments: CommandLine.arguments))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Match routing").font(.title3.weight(.bold))
                    Text(option.title).font(.caption.weight(.semibold)).foregroundStyle(KanameColor.accent)
                    Text(option.summary).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Match design", selection: $option) {
                    ForEach(AutomationMatchDesignOption.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 480)
                Label("Design only", systemImage: "hammer.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.warning)
            }

            HStack(alignment: .top, spacing: 12) {
                AutomationMatchRoutingCanvas(option: option)
                    .frame(maxWidth: .infinity, minHeight: 570)
                AutomationMatchRoutingInspector(option: option)
                    .frame(width: 310)
                    .frame(minHeight: 570)
            }
        }
        .frame(minHeight: 630, alignment: .topLeading)
    }
}

private struct AutomationMatchRoutingCanvas: View {
    let option: AutomationMatchDesignOption

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.accent)
                Text("Readable 100%").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Label("One value in", systemImage: "arrow.right")
                Label(option == .errorRecovery ? "One safe route out" : "One matching route out", systemImage: "arrow.triangle.branch")
            }
            .font(.caption2)

            GeometryReader { proxy in
                ZStack {
                    Canvas { context, size in
                        drawRoutes(context: &context, size: size)
                    }
                    .allowsHitTesting(false)

                    switch option {
                    case .namedPorts:
                        namedPortsNodes(size: proxy.size)
                    case .expandedBoard:
                        expandedBoardNodes(size: proxy.size)
                    case .objectConditions:
                        objectConditionNodes(size: proxy.size)
                    case .errorRecovery:
                        errorRecoveryNodes(size: proxy.size)
                    }
                }
            }
            .background {
                Canvas { context, size in
                    var dots = Path()
                    stride(from: CGFloat(14), through: size.width, by: 18).forEach { x in
                        stride(from: CGFloat(14), through: size.height, by: 18).forEach { y in
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                        }
                    }
                    context.fill(dots, with: .color(KanameColor.separator.opacity(0.38)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.separator, lineWidth: 1) }

            HStack(spacing: 14) {
                Label("Success", systemImage: "checkmark.circle.fill").foregroundStyle(KanameColor.success)
                Label("Error", systemImage: "xmark.octagon.fill").foregroundStyle(KanameColor.danger)
                Label("Match route", systemImage: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                Label("Retry loop", systemImage: "arrow.clockwise").foregroundStyle(KanameColor.external)
                Spacer()
                Text("Case order and fallback are versioned with the workflow")
            }
            .font(.caption2)
        }
        .padding(12)
        .background(KanameColor.surface.opacity(0.46), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func namedPortsNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Extract priority",
            subtitle: "Returns Int",
            symbol: "number",
            success: "value",
            error: "error"
        )
        .frame(width: 165)
        .position(x: size.width * 0.13, y: size.height * 0.50)

        compactMatchNode(
            title: "Match priority",
            input: "Success.value · Int",
            cases: [
                ("5", "Urgent path", KanameColor.danger),
                ("8", "Review path", KanameColor.warning),
                ("_", "Otherwise", KanameColor.accent),
            ]
        )
        .frame(width: 230)
        .position(x: size.width * 0.46, y: size.height * 0.50)

        routeDestination("Urgent", detail: "Notify now", symbol: "bell.badge.fill", tint: KanameColor.danger)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.24)
        routeDestination("Review", detail: "Human decision", symbol: "person.crop.circle.badge.questionmark", tint: KanameColor.warning)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.50)
        routeDestination("Normal", detail: "Continue", symbol: "arrow.right.circle", tint: KanameColor.accent)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.76)
    }

    @ViewBuilder
    private func expandedBoardNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Classify request",
            subtitle: "Returns String?",
            symbol: "tag",
            success: "code",
            error: "error"
        )
        .frame(width: 165)
        .position(x: size.width * 0.11, y: size.height * 0.50)

        expandedMatchBoard
            .frame(width: 340)
            .position(x: size.width * 0.48, y: size.height * 0.50)

        routeDestination("Fast path", detail: "Codes 5 or 8", symbol: "bolt.fill", tint: KanameColor.success)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.19)
        routeDestination("Follow-up", detail: "Range 13…19", symbol: "clock.arrow.circlepath", tint: KanameColor.blocked)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.40)
        routeDestination("Missing value", detail: "Ask for input", symbol: "questionmark.circle", tint: KanameColor.warning)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.61)
        routeDestination("Default", detail: "Safe fallback", symbol: "arrow.down.right.circle", tint: KanameColor.accent)
            .frame(width: 160)
            .position(x: size.width * 0.84, y: size.height * 0.82)
    }

    @ViewBuilder
    private func objectConditionNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Assess request",
            subtitle: "Returns RequestResult",
            symbol: "curlybraces.square",
            success: "result",
            error: "error"
        )
        .frame(width: 175)
        .position(x: size.width * 0.11, y: size.height * 0.50)

        complexObjectMatchBoard
            .frame(width: 380)
            .position(x: size.width * 0.49, y: size.height * 0.50)

        routeDestination("Priority retry", detail: "ALL + nested ANY", symbol: "arrow.clockwise", tint: KanameColor.external)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.25)
        routeDestination("Manual review", detail: "Risk or missing data", symbol: "person.crop.circle.badge.questionmark", tint: KanameColor.warning)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.52)
        routeDestination("Standard path", detail: "Otherwise", symbol: "arrow.right.circle", tint: KanameColor.accent)
            .frame(width: 175)
            .position(x: size.width * 0.85, y: size.height * 0.79)
    }

    @ViewBuilder
    private func errorRecoveryNodes(size: CGSize) -> some View {
        outputProducingNode(
            title: "Apply action",
            subtitle: "Idempotent effect",
            symbol: "checkmark.shield",
            success: "receipt",
            error: "Error.kind"
        )
        .frame(width: 175)
        .position(x: size.width * 0.12, y: size.height * 0.42)

        compactMatchNode(
            title: "Match error",
            input: "Error.kind · ErrorKind",
            cases: [
                ("timeout", "Retry", KanameColor.external),
                ("invalid_input", "Review", KanameColor.warning),
                ("unknown", "Reconcile", KanameColor.danger),
                ("_", "Fail safely", KanameColor.accent),
            ]
        )
        .frame(width: 240)
        .position(x: size.width * 0.44, y: size.height * 0.58)

        routeDestination("Receipt", detail: "Success continues", symbol: "doc.text.magnifyingglass", tint: KanameColor.success)
            .frame(width: 165)
            .position(x: size.width * 0.82, y: size.height * 0.15)
        routeDestination("Retry controller", detail: "Max 3 · backoff", symbol: "arrow.clockwise", tint: KanameColor.external)
            .frame(width: 175)
            .position(x: size.width * 0.74, y: size.height * 0.38)
        routeDestination("Human review", detail: "Correct input", symbol: "person.crop.circle.badge.exclamationmark", tint: KanameColor.warning)
            .frame(width: 175)
            .position(x: size.width * 0.80, y: size.height * 0.62)
        routeDestination("Reconcile", detail: "Never auto-retry", symbol: "questionmark.diamond.fill", tint: KanameColor.danger)
            .frame(width: 175)
            .position(x: size.width * 0.80, y: size.height * 0.84)
    }

    private var expandedMatchBoard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match classification.code").font(.caption.weight(.bold))
                    Text("Expanded while selected · String?").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("FIRST MATCH")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(KanameColor.warning)
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            expandedBoardRow("01", pattern: "5 | 8", destination: "Fast path", tint: KanameColor.success)
            expandedBoardRow("02", pattern: "13…19", destination: "Follow-up", tint: KanameColor.blocked)
            expandedBoardRow("03", pattern: "null", destination: "Missing value", tint: KanameColor.warning)
            expandedBoardRow("04", pattern: "\"blocked\"", destination: "Human review", tint: KanameColor.danger)
            expandedBoardRow("05", pattern: "_ otherwise", destination: "Default", tint: KanameColor.accent)
            Button("Add case", systemImage: "plus") {}
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(KanameColor.accent)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.52), lineWidth: 1.4) }
    }

    private var complexObjectMatchBoard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Match success.result").font(.caption.weight(.bold))
                    Text("RequestResult object · first match").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text("COMPOUND")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(KanameColor.warning)
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            compoundCaseRow(
                "01",
                title: "Priority retry",
                summary: "ALL 2 · nested ANY 1 of 2",
                tint: KanameColor.external
            )
            compoundCaseRow(
                "02",
                title: "Manual review",
                summary: "ANY 2 conditions",
                tint: KanameColor.warning
            )
            compoundCaseRow(
                "03",
                title: "Otherwise",
                summary: "Every valid unmatched value",
                tint: KanameColor.accent
            )

            HStack(spacing: 10) {
                Label("String", systemImage: "textformat")
                Label("Number", systemImage: "number")
                Label("Object", systemImage: "curlybraces")
                Label("Array", systemImage: "square.stack.3d.up")
            }
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(9)
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.52), lineWidth: 1.4) }
    }

    private func compoundCaseRow(_ index: String, title: String, summary: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(index).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Image(systemName: title == "Otherwise" ? "arrow.down.right" : "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 9))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2.weight(.bold))
                Text(summary).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(KanameColor.canvas.opacity(0.55))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func expandedBoardRow(_ index: String, pattern: String, destination: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(index).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(pattern).font(.system(.caption2, design: .monospaced).weight(.semibold)).frame(width: 80, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(tint)
            Text(destination).font(.caption2).lineLimit(1)
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(KanameColor.canvas.opacity(0.55))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func outputProducingNode(
        title: String,
        subtitle: String,
        symbol: String,
        success: String,
        error: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            Divider()
            outputPort("Success · \(success)", tint: KanameColor.success)
            outputPort("Error · \(error)", tint: KanameColor.danger)
        }
        .padding(10)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(KanameColor.accent.opacity(0.45), lineWidth: 1) }
    }

    private func outputPort(_ label: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            Spacer()
            Circle().fill(tint).frame(width: 8, height: 8)
        }
    }

    private func compactMatchNode(
        title: String,
        input: String,
        cases: [(String, String, Color)]
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(KanameColor.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.bold))
                    Text("Typed · first match").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(KanameColor.warning.opacity(0.08))

            HStack(spacing: 6) {
                Circle().fill(KanameColor.accent).frame(width: 7, height: 7)
                Text(input).font(.system(size: 9, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(KanameColor.canvas.opacity(0.65))

            ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 7) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(item.0)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(width: 68, alignment: .leading)
                    Text(item.1).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                    Circle().fill(item.2).frame(width: 8, height: 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(alignment: .bottom) {
                    if index < cases.count - 1 { Divider() }
                }
            }
        }
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(KanameColor.warning.opacity(0.58), lineWidth: 1.5) }
    }

    private func routeDestination(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.bold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.46), lineWidth: 1) }
    }

    private func drawRoutes(context: inout GraphicsContext, size: CGSize) {
        switch option {
        case .namedPorts:
            drawRoute(&context, from: CGPoint(x: size.width * 0.13 + 82, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.46 - 115, y: size.height * 0.50 - 40), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 - 10), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.24), tint: KanameColor.danger)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 + 25), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.50), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: size.width * 0.46 + 115, y: size.height * 0.50 + 60), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.76), tint: KanameColor.accent)
        case .expandedBoard:
            drawRoute(&context, from: CGPoint(x: size.width * 0.11 + 82, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.48 - 170, y: size.height * 0.50 - 125), tint: KanameColor.success)
            let boardX = size.width * 0.48 + 170
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 78), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.19), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 38), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.40), tint: KanameColor.blocked)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 2), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.61), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 82), to: CGPoint(x: size.width * 0.84 - 80, y: size.height * 0.82), tint: KanameColor.accent)
        case .objectConditions:
            drawRoute(&context, from: CGPoint(x: size.width * 0.11 + 87, y: size.height * 0.50 + 13), to: CGPoint(x: size.width * 0.49 - 190, y: size.height * 0.50 - 70), tint: KanameColor.success)
            let boardX = size.width * 0.49 + 190
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 - 42), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.25), tint: KanameColor.external)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 10), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.52), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: boardX, y: size.height * 0.50 + 64), to: CGPoint(x: size.width * 0.85 - 87, y: size.height * 0.79), tint: KanameColor.accent)
        case .errorRecovery:
            drawRoute(&context, from: CGPoint(x: size.width * 0.12 + 87, y: size.height * 0.42 - 7), to: CGPoint(x: size.width * 0.82 - 82, y: size.height * 0.15), tint: KanameColor.success)
            drawRoute(&context, from: CGPoint(x: size.width * 0.12 + 87, y: size.height * 0.42 + 25), to: CGPoint(x: size.width * 0.44 - 120, y: size.height * 0.58 - 54), tint: KanameColor.danger)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 - 18), to: CGPoint(x: size.width * 0.74 - 87, y: size.height * 0.38), tint: KanameColor.external)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 + 18), to: CGPoint(x: size.width * 0.80 - 87, y: size.height * 0.62), tint: KanameColor.warning)
            drawRoute(&context, from: CGPoint(x: size.width * 0.44 + 120, y: size.height * 0.58 + 54), to: CGPoint(x: size.width * 0.80 - 87, y: size.height * 0.84), tint: KanameColor.danger)
            drawRetryLoop(&context, size: size)
        }
    }

    private func drawRoute(
        _ context: inout GraphicsContext,
        from start: CGPoint,
        to end: CGPoint,
        tint: Color
    ) {
        var path = Path()
        path.move(to: start)
        let distance = max(44, abs(end.x - start.x) * 0.44)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + distance, y: start.y),
            control2: CGPoint(x: end.x - distance, y: end.y)
        )
        context.stroke(path, with: .color(tint.opacity(0.78)), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y - 5))
        arrow.addLine(to: CGPoint(x: end.x - 8, y: end.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(tint))
    }

    private func drawRetryLoop(_ context: inout GraphicsContext, size: CGSize) {
        let start = CGPoint(x: size.width * 0.74, y: size.height * 0.38 - 38)
        let end = CGPoint(x: size.width * 0.12, y: size.height * 0.42 - 68)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: size.height * 0.05),
            control2: CGPoint(x: end.x, y: size.height * 0.05)
        )
        context.stroke(path, with: .color(KanameColor.external.opacity(0.9)), style: StrokeStyle(lineWidth: 2.4, dash: [8, 5]))

        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x + 8, y: end.y - 5))
        arrow.addLine(to: CGPoint(x: end.x + 8, y: end.y + 5))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(KanameColor.external))
    }
}

private struct AutomationMatchRoutingInspector: View {
    let option: AutomationMatchDesignOption

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(KanameColor.warning)
                    .frame(width: 30, height: 30)
                    .background(KanameColor.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(inspectorTitle).font(.headline)
                    Text("Deterministic routing · no side effects").font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider()
            inspectorField("Input value", value: inputValue, symbol: option == .errorRecovery ? "xmark.octagon" : "arrow.down.doc")
            inspectorField("Input type", value: inputType, symbol: "curlybraces")
            inspectorField("Selection", value: "First matching case", symbol: "list.number")

            HStack(spacing: 7) {
                Label("Typed", systemImage: "checkmark.seal.fill")
                Label("Ordered", systemImage: "arrow.down")
                Label("Exhaustive", systemImage: "checkmark.circle.fill")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(KanameColor.success)

            Divider()
            HStack {
                Text("Cases").font(.caption.weight(.bold))
                Spacer()
                Text(caseCount).font(.caption2).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(cases.enumerated()), id: \.offset) { index, item in
                    inspectorCase(index + 1, pattern: item.0, destination: item.1, tint: item.2)
                    if index < cases.count - 1 { Divider() }
                }
            }
            .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 9))

            Button("Add case", systemImage: "plus") {}
                .buttonStyle(.bordered)

            if option == .objectConditions {
                complexConditionPanel
            } else if option == .errorRecovery {
                errorSafetyPanel
            } else {
                Label("A value that matches no explicit case must use Otherwise; silent dropping is not allowed.", systemImage: "shield.fill")
                    .font(.caption2)
                    .foregroundStyle(KanameColor.warning)
                    .padding(9)
                    .background(KanameColor.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
            Divider()
            Label("Run history records the input value, selected case, and route edge.", systemImage: "clock.arrow.circlepath")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(KanameColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var inspectorTitle: String {
        switch option {
        case .objectConditions: "Match object"
        case .errorRecovery: "Match error"
        default: "Match value"
        }
    }

    private var inputValue: String {
        switch option {
        case .namedPorts: "Extract priority → Success.value"
        case .expandedBoard: "Classify request → Success.code"
        case .objectConditions: "Assess request → Success.result"
        case .errorRecovery: "Apply action → Error.kind"
        }
    }

    private var inputType: String {
        switch option {
        case .namedPorts: "Int"
        case .expandedBoard: "String?"
        case .objectConditions: "RequestResult object"
        case .errorRecovery: "ErrorKind"
        }
    }

    private var caseCount: String {
        "\(cases.count) outputs"
    }

    private var cases: [(String, String, Color)] {
        switch option {
        case .namedPorts:
            [("5", "Urgent", KanameColor.danger), ("8", "Review", KanameColor.warning), ("_", "Normal", KanameColor.accent)]
        case .expandedBoard:
            [("5 | 8", "Fast path", KanameColor.success), ("13…19", "Follow-up", KanameColor.blocked), ("null", "Missing value", KanameColor.warning), ("\"blocked\"", "Human review", KanameColor.danger), ("_", "Default", KanameColor.accent)]
        case .objectConditions:
            [("ALL + ANY", "Priority retry", KanameColor.external), ("ANY", "Manual review", KanameColor.warning), ("_", "Standard path", KanameColor.accent)]
        case .errorRecovery:
            [(".timeout", "Retry controller", KanameColor.external), (".invalidInput", "Human review", KanameColor.warning), (".unknownOutcome", "Reconcile", KanameColor.danger), ("_", "Fail safely", KanameColor.accent)]
        }
    }

    private func inspectorField(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func inspectorCase(_ index: Int, pattern: String, destination: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Text(String(format: "%02d", index))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Circle().fill(tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(pattern).font(.system(.caption2, design: .monospaced).weight(.bold))
                Text(destination).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "line.diagonal.arrow").font(.caption2).foregroundStyle(tint)
        }
        .padding(8)
    }

    private var errorSafetyPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Retry remains a control node", systemImage: "arrow.clockwise.circle.fill")
                .font(.caption.weight(.bold)).foregroundStyle(KanameColor.external)
            safetyRow("Maximum attempts", value: "3")
            safetyRow("Backoff", value: "2 s · ×2 · jitter")
            safetyRow("Idempotency", value: "Required")
            safetyRow("Unknown outcome", value: "Never auto-retry")
        }
        .padding(9)
        .background(KanameColor.external.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.external.opacity(0.28), lineWidth: 1) }
    }

    private var complexConditionPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Priority retry", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KanameColor.external)
                Spacer()
                Text("ALL").font(.system(size: 9, weight: .bold, design: .monospaced))
            }

            conditionRow("status", relation: "equals", value: "failed", tint: KanameColor.success)
            conditionRow("error.retryable", relation: "is", value: "true", tint: KanameColor.success)

            HStack {
                Text("AND").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Divider()
                Text("ANY · 1 of 2").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(KanameColor.accent)
                Spacer()
                Button("+ condition") {}.buttonStyle(.plain).font(.system(size: 9))
            }
            .frame(height: 18)

            conditionRow("customer.tier", relation: "equals", value: "priority", tint: KanameColor.accent)
            conditionRow("value", relation: "≥", value: "10,000", tint: KanameColor.accent)

            HStack(spacing: 7) {
                Button("+ AND") {}.buttonStyle(.bordered).controlSize(.mini)
                Button("+ ANY") {}.buttonStyle(.bordered).controlSize(.mini)
                Button("+ NOT") {}.buttonStyle(.bordered).controlSize(.mini)
                Spacer()
                Label("Fixture matched", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(KanameColor.success)
            }
        }
        .padding(9)
        .background(KanameColor.external.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(KanameColor.external.opacity(0.26), lineWidth: 1) }
    }

    private func conditionRow(_ field: String, relation: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(field).font(.system(size: 9, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text(relation).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(value).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(KanameColor.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private func safetyRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.caption2)
    }
}
