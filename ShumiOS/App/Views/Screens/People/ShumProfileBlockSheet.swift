import SwiftUI
import UIKit

struct ShumProfileBlockRequest: Identifiable {
    let id = UUID()
    let peer: ShumPeer
    let card: ShumContactCard
    let waitsForTransientUI: Bool
}
private struct ShumProfileBlockSheetModifier: ViewModifier {
    @Environment(\.shumCaptureProtectionEnabled) private var protectsCapture
    @ObservedObject var runtime: ShumRuntime
    @Binding var request: ShumProfileBlockRequest?
    @State private var activeRequest: ShumProfileBlockRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $activeRequest) { pending in
                ShumProfileBlockOptionsSheet(
                    runtime: runtime,
                    request: pending,
                    onClose: { activeRequest = nil },
                    onBlock: { block(pending) }
                )
                .shumProtectFromCapture(protectsCapture)
                .presentationDetents([.height(195)])
                .presentationDragIndicator(.hidden)
            }
            .task(id: request?.id) {
                guard let pending = request else { return }
                if pending.waitsForTransientUI {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard !Task.isCancelled, request?.id == pending.id else { return }
                activeRequest = pending
            }
            .onChange(of: activeRequest?.id) { id in
                if id == nil { request = nil }
            }
    }

    private func block(_ pending: ShumProfileBlockRequest) {
        do {
            try runtime.permanent?.setBlocked(pending.card, blocked: true)
            activeRequest = nil
        } catch {
            runtime.error = error.localizedDescription
        }
    }
}
private struct ShumProfileBlockOptionsSheet: View {
    @ObservedObject var runtime: ShumRuntime
    let request: ShumProfileBlockRequest
    let onClose: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ShumProfileAvatar(
                    name: runtime.displayName(request.peer),
                    size: 44,
                    imageData: runtime.profile(for: request.peer.id)?.avatar
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Заблокировать пользователя?".localized)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(runtime.displayName(request.peer))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(
                            Color(uiColor: .tertiarySystemFill),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть".localized)
            }

            VStack(spacing: 0) {
                Button(role: .destructive, action: onBlock) {
                    HStack(spacing: 18) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 20, weight: .regular))
                            .frame(width: 22)

                        Text("Заблокировать".localized)
                            .font(.system(size: 16))

                        Spacer()
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}
extension View {
    func shumProfileBlockSheet(
        runtime: ShumRuntime,
        request: Binding<ShumProfileBlockRequest?>
    ) -> some View {
        modifier(
            ShumProfileBlockSheetModifier(
                runtime: runtime,
                request: request
            )
        )
    }
}
