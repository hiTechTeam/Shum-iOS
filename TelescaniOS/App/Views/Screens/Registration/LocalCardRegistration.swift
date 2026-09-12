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
                isEnabled: photoViewModel.uiImage != nil, accentColor: .blue) { showDetails = true }
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24).background(Color("ls-Background").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showDetails) {
            LocalCardDetailsView(profile: coordinator.authCodeViewModel, photo: photoViewModel) {
                coordinator.completedRegistration()
            }
        }
    }
}

enum LocalCardDetailsMode: String, Identifiable {
    case registration, name, telegram
    var id: Self { self }
    var showsName: Bool { self != .telegram }
    var showsUsername: Bool { self != .name }
    var title: LocalizedStringKey {
        switch self {
        case .registration: "local.onboarding.details.title"
        case .name: "local.profile.name"
        case .telegram: "Telegram username"
        }
    }
}

struct LocalCardDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profile: LocalProfileViewModel
    @ObservedObject var photo: ProfilePhotoViewModel
    var mode: LocalCardDetailsMode = .registration
    let onSave: () -> Void
    @State private var name = ""
    @State private var username = ""
    @FocusState private var focused: Field?
    private enum Field { case username, name }
    private var valid: Bool {
        (!mode.showsUsername || LocalCardManifest.username(username) != nil) &&
        (!mode.showsName || (!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 64))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if mode == .registration {
                    Text(mode.title).font(.largeTitle.bold())
                }
                if mode.showsUsername {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Telegram username").font(.headline)
                    TextField("@username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.asciiCapable).textContentType(.username)
                        .focused($focused, equals: .username)
                        .submitLabel(mode == .registration ? .next : .done)
                        .onSubmit { focused = mode == .registration ? .name : nil }
                        .padding(16)
                        .background(
                            Color.tField,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .accessibilityIdentifier("local.username")
                    Text("local.username.explanation").font(.footnote).foregroundStyle(.secondary)
                }
                }
                if mode.showsName {
                VStack(alignment: .leading, spacing: 10) {
                    Text("local.profile.name").font(.headline)
                    TextField("local.profile.name", text: $name)
                        .textContentType(.nickname).focused($focused, equals: .name).submitLabel(.done).onSubmit { focused = nil }
                        .padding(16)
                        .background(
                            Color.tField,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                        .accessibilityIdentifier("local.name")
                    Text("local.name.explanation").font(.footnote).foregroundStyle(.secondary)
                }
                }
                if let error = profile.saveError { Text(error).foregroundStyle(.red).font(.footnote) }
                if mode == .registration {
                    Text("local.sharing.explanation").font(.footnote).foregroundStyle(.secondary)
                }
                RegistrationPrimaryButton(title: NSLocalizedString("local.profile.save", comment: ""), isEnabled: valid, accentColor: .blue) {
                    let saved: Bool
                    switch mode {
                    case .registration: saved = profile.save(name: name, username: username, photo: photo.preparedPhoto)
                    case .name: saved = profile.updateName(name)
                    case .telegram: saved = profile.updateUsername(username)
                    }
                    if saved {
                        focused = nil; onSave()
                    }
                }
                .padding(.top, 12).accessibilityIdentifier("local.save")
            }.padding(24)
        }
        .background(Color("ls-Background").ignoresSafeArea()).scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode != .registration {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.close.localized) { dismiss() }
                }
            }
        }
        .onAppear {
            name = profile.tgName ?? ""; username = profile.tgUsername ?? ""
            profile.saveError = nil
        }
    }
}
