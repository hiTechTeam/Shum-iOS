import SwiftUI

struct BioEditorField: View {
    @Binding var text: String

    let isSaving: Bool
    let saveFailed: Bool

    private let characterLimit = 60
    private let cornerRadius: CGFloat = 13

    private var characterCount: String {
        "\(text.count)/\(characterLimit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(characterCount)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                TextField(
                    Inc.Profile.bioPlaceholder.localized,
                    text: $text,
                    axis: .vertical
                )
                .font(.system(size: 16))
                .lineLimit(2...3)
                .disabled(isSaving)
                .onChange(of: text) { _, value in
                    guard value.count > characterLimit else { return }
                    text = String(value.prefix(characterLimit))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: 96, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.tField.opacity(0.8))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        saveFailed ? Color.red.opacity(0.7) : Color.clear,
                        lineWidth: 1
                    )
            }

            if saveFailed {
                Text(Inc.Profile.bioSaveFailed.localized)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: saveFailed)
    }
}

struct BioProfileField: View {
    @ObservedObject var authVM: CodeViewModel

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
                saveFailed: false
            )
            .allowsHitTesting(false)

            Button(action: openEditor) {
                Color.clear
                    .frame(width: 360, height: 96)
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
        .onChange(of: showEditor) { _, isPresented in
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
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(authVM.isSavingBio)
        }
    }
}

struct BioEditorSheet: View {
    @Binding var draftBio: String
    @Binding var isPresented: Bool

    @ObservedObject var authVM: CodeViewModel

    private func apply() {
        Task {
            if await authVM.updateBio(draftBio) {
                isPresented = false
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                BioEditorField(
                    text: $draftBio,
                    isSaving: authVM.isSavingBio,
                    saveFailed: authVM.bioSaveFailed
                )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.cancel.localized) {
                        isPresented = false
                    }
                    .frame(width: 92, alignment: .leading)
                    .disabled(authVM.isSavingBio)
                }

                ToolbarItem(placement: .principal) {
                    Text(Inc.Profile.informationTitle.localized)
                        .font(.headline)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Profile.saveName.localized, action: apply)
                        .frame(width: 92, alignment: .trailing)
                        .fontWeight(.semibold)
                        .disabled(authVM.isSavingBio)
                }
            }
        }
    }
}
