import OSLog
import SwiftUI

@MainActor
final class ProfilePhotoViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Telescan",
        category: "ProfilePhoto"
    )

    @Published var profileImage: Image = .noPhoto
    @Published var uiImage: UIImage?
    private let photoS3UrlKey = "photoS3Url"

    private var photoLoadTask: Task<Void, Never>?

    init() {
        loadPhotoIfNeeded()
    }

    func loadPhotoIfNeeded() {
        if let savedImage = ProfileImageStorage.load() {
            uiImage = savedImage
            profileImage = Image(uiImage: savedImage)
            return
        }

        let savedURL = UserDefaults.standard.string(
            forKey: photoS3UrlKey
        )

        loadPhotoFromURL(savedURL)
    }

    func loadPhotoFromURL(_ urlString: String?) {
        photoLoadTask?.cancel()
        photoLoadTask = nil

        guard let urlString,
              let url = URL(string: urlString) else {
            uiImage = nil
            profileImage = .noPhoto

            ProfileImageStorage.delete()

            UserDefaults.standard.removeObject(
                forKey: photoS3UrlKey
            )

            return
        }

        UserDefaults.standard.set(
            urlString,
            forKey: photoS3UrlKey
        )

        photoLoadTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let data = try await fetchData(from: url)

                try Task.checkCancellation()

                guard let loadedImage = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }

                uiImage = loadedImage
                profileImage = Image(uiImage: loadedImage)

                ProfileImageStorage.save(loadedImage)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error(
                    "Failed to load photo: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func updateProfileImage(with newImage: UIImage?) {
        Task { [weak self] in
            guard let self else {
                return
            }

            guard let originalImage = newImage else {
                do {
                    try await FetchService.fetch
                        .deleteProfileImage()

                    photoLoadTask?.cancel()
                    photoLoadTask = nil

                    uiImage = nil
                    profileImage = .noPhoto

                    ProfileImageStorage.delete()

                    UserDefaults.standard.removeObject(
                        forKey: photoS3UrlKey
                    )
                } catch {
                    Self.logger.error(
                        "Failed to delete profile image: \(error.localizedDescription, privacy: .private)"
                    )
                }

                return
            }

            let resizedImage = originalImage.resized(
                maxSide: 1024
            )

            guard let compressedData = resizedImage.compressed(
                quality: 0.65
            ),
            let compressedImage = UIImage(
                data: compressedData
            ) else {
                return
            }

            do {
                let photoURL = try await FetchService.fetch
                    .updateProfileImage(data: compressedData)

                photoLoadTask?.cancel()
                photoLoadTask = nil

                uiImage = compressedImage
                profileImage = Image(
                    uiImage: compressedImage
                )

                ProfileImageStorage.save(compressedImage)

                UserDefaults.standard.set(
                    photoURL.photoUrl,
                    forKey: photoS3UrlKey
                )
            } catch {
                Self.logger.error(
                    "Failed to upload profile image: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func fetchData(
        from url: URL
    ) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )

        request.setValue(
            "no-cache",
            forHTTPHeaderField: "Cache-Control"
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let httpResponse =
                response as? HTTPURLResponse,
              (200...299).contains(
                httpResponse.statusCode
              ) else {
            throw URLError(.badServerResponse)
        }

        return data
    }
}

extension UIImage {

    func resized(maxSide: CGFloat) -> UIImage {
        let maxCurrentSide = max(
            size.width,
            size.height
        )

        guard maxCurrentSide > maxSide else {
            return self
        }

        let scale = maxSide / maxCurrentSide

        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let renderer = UIGraphicsImageRenderer(
            size: newSize
        )

        return renderer.image { _ in
            self.draw(
                in: CGRect(
                    origin: .zero,
                    size: newSize
                )
            )
        }
    }

    func compressed(
        quality: CGFloat = 0.65
    ) -> Data? {
        jpegData(compressionQuality: quality)
    }
}
