import SwiftUI

struct QuickActionsSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = QuickActionsSettingsStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Inc.QuickActions.description.localized)
                        .telescanDescriptionStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
                        QuickActionToggleRow(
                            title: Inc.QuickActions.chat.localized,
                            description: Inc.QuickActions.chatDescription
                                .localized,
                            systemImage: "paperplane",
                            isOn: $settings.isQuickChatEnabled
                        )

                        Divider()
                            .padding(.leading, 60)
                            .padding(.trailing, 16)

                        QuickActionToggleRow(
                            title: Inc.QuickActions.clear.localized,
                            description: Inc.QuickActions.clearDescription
                                .localized,
                            systemImage: "trash",
                            isOn: $settings.isQuickClearEnabled
                        )

                        Divider()
                            .padding(.leading, 60)
                            .padding(.trailing, 16)

                        QuickActionToggleRow(
                            title: Inc.QuickActions.block.localized,
                            description: Inc.QuickActions.blockDescription
                                .localized,
                            systemImage: "person.crop.circle.badge.xmark",
                            isOn: $settings.isQuickBlockEnabled
                        )
                    }
                    .modifier(QuickActionsGroupBackground())
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .background(
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.QuickActions.title.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct QuickActionsGroupBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: .rect(cornerRadius: 22)
            )
        } else {
            content
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .clipShape(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
        }
    }
}

private struct QuickActionToggleRow: View {
    let title: String
    let description: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 68)
        .contentShape(Rectangle())
    }
}
