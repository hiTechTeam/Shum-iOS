import SwiftUI

struct BioEditorField: View {
    @Binding var text: String

    let isSaving: Bool
    let saveFailed: Bool
    let contentRejected: Bool

    private let characterLimit = 36
    private let cornerRadius: CGFloat = 18

    private var characterCount: String {
        "\(text.count)/\(characterLimit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(
                    Inc.Profile.bioPlaceholder.localized,
                    text: $text,
                    axis: .vertical
                )
                .font(.system(size: 16))
                .lineLimit(1...2)
                .disabled(isSaving)
                .shumOnChange(of: text) { _, value in
                    guard value.count > characterLimit else { return }
                    text = String(value.prefix(characterLimit))
                }
                .onAppear {
                    guard text.count > characterLimit else { return }
                    text = String(text.prefix(characterLimit))
                }

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(characterCount)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        saveFailed ? Color.red.opacity(0.7) : Color.clear,
                        lineWidth: 1
                    )
            }

            if saveFailed {
                Text(
                    contentRejected
                        ? Inc.Profile.bioContentRejected.localized
                        : Inc.Profile.bioSaveFailed.localized
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: saveFailed)
    }
}

struct BioProfileField: View {
    @ObservedObject var authVM: LocalProfileViewModel

    @State private var draftBio = ""
    @State private var showEditor = false

    private func openEditor() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        draftBio = authVM.bio ?? ""
        authVM.resetBioSaveState()
        showEditor = true
    }

    var body: some View {
        ZStack {
            BioEditorField(
                text: $draftBio,
                isSaving: false,
                saveFailed: false,
                contentRejected: false
            )
            .allowsHitTesting(false)

            Button(action: openEditor) {
                Color.clear
                    .frame(width: 360, height: 64)
                    .contentShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel("BIO")
        .accessibilityValue(draftBio)
        .accessibilityAddTraits(.isButton)
        .onAppear {
            draftBio = authVM.bio ?? ""
        }
        .shumOnChange(of: showEditor) { _, isPresented in
            if !isPresented {
                draftBio = authVM.bio ?? ""
            }
        }
        .sheet(isPresented: $showEditor) {
            BioEditorSheet(
                draftBio: $draftBio,
                isPresented: $showEditor,
                authVM: authVM
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(authVM.isSavingBio)
        }
    }
}

struct BioEditorSheet: View {
    @Binding var draftBio: String
    @Binding var isPresented: Bool

    @ObservedObject var authVM: LocalProfileViewModel

    private func apply() {
        Task {
            if await authVM.updateBio(String(draftBio.prefix(36))) {
                isPresented = false
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                BioEditorField(
                    text: $draftBio,
                    isSaving: authVM.isSavingBio,
                    saveFailed: authVM.bioSaveFailed,
                    contentRejected: authVM.bioContentRejected
                )

                Text(Inc.Profile.informationDescription.localized)
                    .shumDescriptionStyle()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresented = false
                    } label: {
                        Text(Inc.Common.cancel.localized)
                            .fixedSize()
                            .frame(width: 92, alignment: .leading)
                    }
                    .disabled(authVM.isSavingBio)
                }

                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.informationTitle.localized)
                        .shumSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: apply) {
                        Text(Inc.Profile.saveName.localized)
                            .fontWeight(.semibold)
                            .fixedSize()
                            .frame(width: 92, alignment: .trailing)
                    }
                    .disabled(authVM.isSavingBio)
                }
            }
        }
    }
}
