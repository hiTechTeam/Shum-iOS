import SwiftUI

struct LocalCardRegistration: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var photoViewModel: ProfilePhotoViewModel
    @State private var pendingName = ""
    @State private var showPhoto = false

    var body: some View {
        LocalCardDetailsView(
            profile: coordinator.authCodeViewModel,
            photo: photoViewModel,
            onSave: { },
            onRegistrationContinue: { name in
                pendingName = name
                showPhoto = true
            }
        )
        .navigationDestination(isPresented: $showPhoto) {
            LocalCardPhotoRegistration(
                name: pendingName,
                photoViewModel: photoViewModel
            )
        }
    }
}

private struct LocalCardPhotoRegistration: View {
    let name: String
    @ObservedObject var photoViewModel: ProfilePhotoViewModel
    @State private var showSecurityCreation = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("local.onboarding.photo.title").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("local.onboarding.photo.description").foregroundStyle(.secondary).multilineTextAlignment(.center)
            ProfilePhotoView(
                viewModel: photoViewModel,
                name: name
            )
            Spacer()
            RegistrationPrimaryButton(title: Inc.Onboarding.photoNext.localized,
                isEnabled: true, accentColor: .accentColor) { showSecurityCreation = true }
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24).background(ShumThemeCanvas().ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showSecurityCreation) {
            RegistrationSecurityCreationView(
                name: name,
                photo: photoViewModel.preparedPhoto,
                photoEditing: photoViewModel.photoEditing
            )
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
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var profile: LocalProfileViewModel
    @ObservedObject var photo: ProfilePhotoViewModel
    var mode: LocalCardDetailsMode = .registration
    let onSave: () -> Void
    var onRegistrationContinue: ((String) -> Void)? = nil
    @State private var name = ""
    @FocusState private var focused: Bool
    private var valid: Bool { ShumProfileValidation.name(name) != nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if mode == .registration { Text(mode.title).font(.largeTitle.bold()) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Имя".localized)
                        .font(.system(size: 17, weight: .regular))
                    TextField("Имя пользователя".localized, text: $name)
                        .textContentType(.nickname).textInputAutocapitalization(.never)
                        .focused($focused).submitLabel(.done).onSubmit { save() }
                        .padding(16)
                        .background(Color.tField, in: Capsule())
                        .accessibilityIdentifier("local.name")
                    Text("Так вас увидят собеседники.".localized)
                        .font(.footnote).foregroundStyle(.secondary)
                    if !name.isEmpty && !valid {
                        Text("Сократите имя и уберите переносы строки.".localized)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = profile.saveError { Text(error).foregroundStyle(.red).font(.footnote) }
                RegistrationPrimaryButton(
                    title: mode == .registration
                        ? Inc.Onboarding.photoNext.localized
                        : "local.profile.save".localized,
                    isEnabled: valid,
                    action: save
                )
                    .padding(.top, 12).accessibilityIdentifier("local.save")
            }.padding(24)
        }
        .background(ShumThemeCanvas().ignoresSafeArea()).scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode != .registration {
                ToolbarItem(placement: .cancellationAction) { Button(Inc.Common.close.localized) { dismiss() } }
            }
        }
        .onAppear { name = profile.localName ?? ""; profile.saveError = nil }
    }
    private func save() {
        guard let value = ShumProfileValidation.name(name) else { return }
        if mode == .registration {
            focused = false
            onRegistrationContinue?(value)
        } else if profile.updateName(value) {
            focused = false
            onSave()
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
