import SwiftUI

struct BioEditorField: View {
    @Binding var text: String

    let isSaving: Bool
    let saveFailed: Bool

    private let characterLimit = 60
    private let fieldWidth: CGFloat = 360
    private let cornerRadius: CGFloat = 13

    private var characterCount: String {
        "\(text.count)/\(characterLimit)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(Inc.Profile.bioTitle.localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

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
            .frame(width: fieldWidth, alignment: .topLeading)
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
                    .frame(width: fieldWidth, alignment: .leading)
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

private struct BioEditorSheet: View {
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

                Button(action: apply) {
                    Text(Inc.Profile.bioApply.localized)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(authVM.isSavingBio)
                .frame(width: 360)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)
            .navigationTitle("BIO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.cancel.localized) {
                        isPresented = false
                    }
                    .disabled(authVM.isSavingBio)
                }
            }
        }
    }
}
