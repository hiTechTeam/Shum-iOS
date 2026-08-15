import SwiftUI
import Kingfisher

struct PeopleView: View {

    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var peopleViewModel: PeopleViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedUser: NearbyUser?

    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                if coordinator.isScaning {
                    List {
                        if peopleViewModel.visibleUsers.isEmpty {
                            VStack(
                                alignment: .leading,
                                spacing: 12
                            ) {
                                Image.wave3Up
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(.gray)

                                Text(Inc.Scanning.noPeopleNeaby.localized)
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.gray)
                            }
                            .padding(.top, 12)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 0,
                                    leading: 16,
                                    bottom: 0,
                                    trailing: 16
                                )
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(
                            peopleViewModel.visibleUsers
                        ) { user in
                            Button {
                                selectedUser = user
                            } label: {
                                PeopleRowContent(user: user)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await peopleViewModel.refreshNearbyPeople()
                    }
                }
            }
        }
        .onChange(of: scenePhase) {  _, newPhase in
            guard newPhase == .active else {
                return
            }

            guard coordinator.isScaning else {
                return
            }

            Task {
                await peopleViewModel.refreshVisibleUsers()
            }
        }
        .onChange(of: peopleViewModel.visibleUsers.map(\.id)) { _, ids in
            if let selectedUser, !ids.contains(selectedUser.id) {
                self.selectedUser = nil
            }
        }
        .sheet(item: $selectedUser) { user in
            ProfileSheetView(user: user)
                .environmentObject(peopleViewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }
}

struct PeopleRowContent: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel

    let user: NearbyUser

    var body: some View {
        HStack(spacing: 12) {
            if let url = user.photoURL,
               let imageURL = URL(string: url) {
                KFImage(imageURL)
                    .placeholder {
                        Image.personCropCircleFill
                            .resizable()
                            .foregroundColor(.gray)
                    }
                    .resizable()
                    .scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())
                    .clipped()
            } else {
                Image.personCropCircleFill
                    .resizable()
                    .foregroundColor(.gray)
                    .frame(width: 56, height: 56)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    user.name
                )
                .foregroundColor(.gray)
                .font(.system(size: 14))

                Text(
                    user.username
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
            }

            Spacer()

            if let meters = peopleViewModel.distances[user.discoveryID] {
                Text(
                    String.localizedStringWithFormat(
                        Inc.Common.distanceMetersFormat.localized,
                        meters
                    )
                )
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .padding(.trailing, 20)
            }
        }
    }
}

struct ProfileSheetView: View {

    @EnvironmentObject var peopleViewModel: PeopleViewModel
    @Environment(\.dismiss) private var dismiss

    let user: NearbyUser

    var body: some View {
        ZStack {
            VStack {
                Spacer(minLength: 0)

                if let url = user.photoURL,
                   let imageURL = URL(string: url) {
                    GeometryReader { geo in
                        let maxSize = min(
                            geo.size.width,
                            geo.size.height
                        ) - 24

                        let strokeWidth: CGFloat = 6

                        KFImage(imageURL)
                            .placeholder {
                                Image.personCropCircleFill
                                    .resizable()
                                    .foregroundColor(.gray)
                            }
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: maxSize,
                                height: maxSize
                            )
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        Color.gray,
                                        lineWidth: strokeWidth
                                    )
                                    .padding(-strokeWidth)
                                    .opacity(0.3)
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                    }
                } else {
                    Image.personCropCircleFill
                        .resizable()
                        .foregroundColor(.gray)
                        .frame(width: 300, height: 300)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(
                            user.name
                        )
                        .font(.title)
                        .bold()

                        HStack(spacing: 8) {
                            Text(Inc.Common.nearby.localized)
                                .font(.system(size: 14))
                                .foregroundColor(.gray)

                            if let meters = peopleViewModel.distances[
                                user.discoveryID
                            ] {
                                Text(
                                    String.localizedStringWithFormat(
                                        Inc.Common.distanceMetersFormat.localized,
                                        meters
                                    )
                                )
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                        }
                    }

                    CopyUsernameField(username: user.username)
                }
            }
            .padding(.top, 60)

            Button(
                action: {
                    dismiss()
                },
                label: {
                    Image.xmarkCircleFill
                        .font(.system(size: 28))
                        .foregroundColor(.gray)
                        .opacity(0.5)
                }
            )
            .padding(.top, 20)
            .padding(.trailing, 20)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
        }
    }
}
