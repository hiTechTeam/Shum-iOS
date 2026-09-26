import SwiftUI

struct BlockedProfilesView: View {
    @ObservedObject var runtime: ShumRuntime
    @Environment(\.colorScheme) private var colorScheme

    @State private var profileBeingUnblocked: String?
    @State private var showError = false

    private var blockedCards: [ShumContactCard] {
        (runtime.permanent?.state.blocked?.values.map { $0 } ?? [])
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if blockedCards.isEmpty {
                    ShumBlockedProfilesEmptyState()
                } else {
                    List(blockedCards) { card in
                        HStack(spacing: 12) {
                            ShumAvatar(
                                name: card.name,
                                size: 44,
                                imageData: runtime.profile(for: card.peerID)?.avatar
                            )

                            Text(card.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            if profileBeingUnblocked == card.id {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(minWidth: 44)
                            } else {
                                Button(Inc.NearbyProfile.unblock.localized) {
                                    unblock(card)
                                }
                                .buttonStyle(.borderless)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .disabled(profileBeingUnblocked != nil)
                            }
                        }
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: 16,
                                bottom: 8,
                                trailing: 16
                            )
                        )
                    }
                    .listStyle(.plain)
                    .shumGroupedScreenBackground()
                }
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.NearbyProfile.blockedProfiles.localized)
                        .shumSheetTitleStyle()
                }
            }
        }
        .alert(
            Inc.NearbyProfile.actionFailedTitle.localized,
            isPresented: $showError
        ) {
            Button(Inc.NearbyProfile.acknowledge.localized, role: .cancel) { }
        } message: {
            Text(Inc.NearbyProfile.actionFailedMessage.localized)
        }
    }

    private func unblock(_ card: ShumContactCard) {
        guard profileBeingUnblocked == nil else { return }
        profileBeingUnblocked = card.id
        Task { @MainActor in
            do {
                try runtime.permanent?.setBlocked(card, blocked: false)
            } catch {
                showError = true
            }
            profileBeingUnblocked = nil
        }
    }
}

private struct ShumBlockedProfilesEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            ShumPixelEmptyIcon(kind: .blocked)
                .foregroundStyle(.primary)
                .frame(width: 88, height: 68)
                .accessibilityHidden(true)

            Text("Никого не заблокировано".localized)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text("Заблокированные пользователи появятся здесь.".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: 330)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}
