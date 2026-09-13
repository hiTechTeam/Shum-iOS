import SwiftUI

struct LocalCardRegistration: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var photoViewModel: ProfilePhotoViewModel
    @State private var showDetails = false
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("local.onboarding.photo.title").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("local.onboarding.photo.description").foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProfilePhotoView(viewModel: photoViewModel)
            Spacer()
            RegistrationPrimaryButton(title: Inc.Onboarding.photoNext.localized,
                isEnabled: true, accentColor: .accentColor) { showDetails = true }
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24).background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showDetails) {
            LocalCardDetailsView(
                profile: coordinator.authCodeViewModel,
                photo: photoViewModel
            ) { }
        }
    }
}

enum LocalCardDetailsMode: String, Identifiable {
    case registration, name
    var id: Self { self }
    var title: LocalizedStringKey { self == .registration ? "local.onboarding.details.title" : "local.profile.name" }
}

struct LocalCardDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profile: LocalProfileViewModel
    @ObservedObject var photo: ProfilePhotoViewModel
    var mode: LocalCardDetailsMode = .registration
    let onSave: () -> Void
    @State private var name = ""
    @State private var showSecurity = false
    @FocusState private var focused: Bool
    private var valid: Bool { ShumProfileValidation.name(name) != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if mode == .registration { Text(mode.title).font(.largeTitle.bold()) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("local.profile.name").font(.headline)
                    TextField("Имя пользователя", text: $name)
                        .textContentType(.nickname).textInputAutocapitalization(.never)
                        .focused($focused).submitLabel(.done).onSubmit { save() }
                        .padding(16)
                        .background(Color.tField, in: Capsule())
                        .accessibilityIdentifier("local.name")
                    Text("Так вас увидят собеседники.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !name.isEmpty && !valid {
                        Text("Сократите имя и уберите переносы строки.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = profile.saveError { Text(error).foregroundStyle(.red).font(.footnote) }
                RegistrationPrimaryButton(title: NSLocalizedString("local.profile.save", comment: ""), isEnabled: valid, action: save)
                    .padding(.top, 12).accessibilityIdentifier("local.save")
            }.padding(24)
        }
        .background(Color("ls-Background").ignoresSafeArea()).scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode != .registration {
                ToolbarItem(placement: .cancellationAction) { Button(Inc.Common.close.localized) { dismiss() } }
            }
        }
        .navigationDestination(isPresented: $showSecurity) {
            RegistrationSecurityReadyView()
        }
        .onAppear { name = profile.localName ?? ""; profile.saveError = nil }
    }
    private func save() {
        guard let value = ShumProfileValidation.name(name) else { return }
        let saved = mode == .registration ? profile.save(name: value, photo: photo.preparedPhoto) : profile.updateName(value)
        if saved {
            focused = false
            if mode == .registration {
                showSecurity = true
            } else {
                onSave()
            }
        }
    }
}

enum ShumProfileValidation {
    static func name(_ value: String) -> String? {
        guard let value = InputValidator.validateNickname(value), value.utf8.count <= 64,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}
