import KanameDesktop
import KanameDesignSystem
import SwiftUI

/// Shared chrome for composer `/` command and `$` skill pickers so intentional
/// UX parity does not duplicate drawer scaffolding.
struct DesktopComposerPickerDrawerFrame<Content: View>: View {
    let title: String
    let systemImage: String
    let matchCount: Int
    let emptyMessage: String
    let accessibilityLabel: String
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KanameColor.accent)
                Spacer()
                Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)

            if matchCount == 0 {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.bottom, 9)
            } else {
                content()
                    .frame(maxHeight: maxHeight)
            }
        }
        .background(KanameColor.raised.opacity(0.98), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(KanameColor.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(matchCount) available")
    }
}

struct DesktopComposerPickerRowChrome<Title: View, Detail: View>: View {
    let isSelected: Bool
    let isEnabled: Bool
    let systemImage: String
    @ViewBuilder let title: () -> Title
    @ViewBuilder let detail: () -> Detail
    let action: () -> Void
    let onHoverSelect: () -> Void
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isEnabled ? KanameColor.accent : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title()
                    detail()
                        .font(.caption)
                        .foregroundStyle(isEnabled ? Color.secondary : KanameColor.warning)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KanameColor.surface)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                isSelected ? KanameColor.accent.opacity(isEnabled ? 1 : 0.62) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(isSelected ? KanameColor.canvas : Color.primary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            if hovering { onHoverSelect() }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }
}

struct DesktopComposerCommandDrawer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let query: String
    let commands: [DesktopComposerCommand]
    let selectedCommandID: DesktopComposerCommandID?
    let keyboardScrollRevision: UInt
    let select: (DesktopComposerCommandID) -> Void
    let activate: (DesktopComposerCommandID) -> Void

    var body: some View {
        DesktopComposerPickerDrawerFrame(
            title: "Commands",
            systemImage: "command",
            matchCount: commands.count,
            emptyMessage: "No local command matches /\(query). Press Return to send this as ordinary chat text.",
            accessibilityLabel: "Composer commands",
            maxHeight: 238
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(commands) { command in
                            commandRow(command)
                                .id(command.id)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 5)
                }
                .onChange(of: keyboardScrollRevision) { _, _ in
                    guard let selectedCommandID,
                          commands.contains(where: { $0.id == selectedCommandID }) else { return }
                    if reduceMotion {
                        proxy.scrollTo(selectedCommandID, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedCommandID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func commandRow(_ command: DesktopComposerCommand) -> some View {
        let isSelected = command.id == selectedCommandID
        return DesktopComposerPickerRowChrome(
            isSelected: isSelected,
            isEnabled: command.isEnabled,
            systemImage: command.systemImage,
            title: {
                Text(
                    "\(Text(command.invocation).font(.system(.callout, design: .monospaced).weight(.semibold))) "
                        + "\(Text(command.title).font(.callout.weight(.medium)))"
                )
            },
            detail: {
                Text(command.disabledReason ?? command.detail)
            },
            action: { activate(command.id) },
            onHoverSelect: { select(command.id) },
            accessibilityLabel: "\(command.invocation), \(command.title)",
            accessibilityValue: "\(isSelected ? "Selected. " : "")\(command.disabledReason ?? command.detail)",
            accessibilityHint: command.isEnabled ? "Press Return or Tab to run locally" : "Unavailable"
        )
    }
}

struct DesktopComposerSkillDrawer: View {
    let query: String
    let skills: [DesktopComposerSkill]
    let selectedIndex: Int
    let select: (Int) -> Void
    let activate: (DesktopComposerSkill) -> Void

    var body: some View {
        DesktopComposerPickerDrawerFrame(
            title: "Skills",
            systemImage: "sparkles",
            matchCount: skills.count,
            emptyMessage: "No skill matches $\(query). Loaded skill bodies are injected when you send.",
            accessibilityLabel: "Composer skills",
            maxHeight: 180
        ) {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                        skillRow(skill, isSelected: index == selectedIndex)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 5)
            }
        }
    }

    private func skillRow(_ skill: DesktopComposerSkill, isSelected: Bool) -> some View {
        DesktopComposerPickerRowChrome(
            isSelected: isSelected,
            isEnabled: true,
            systemImage: "sparkles",
            title: {
                Text("$\(skill.name)")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
            },
            detail: {
                Text(skill.description)
            },
            action: { activate(skill) },
            onHoverSelect: {
                if let index = skills.firstIndex(where: { $0.id == skill.id }) {
                    select(index)
                }
            },
            accessibilityLabel: "$\(skill.name)",
            accessibilityValue: "\(isSelected ? "Selected. " : "")\(skill.description)",
            accessibilityHint: "Press Return to insert this skill mention"
        )
    }
}
