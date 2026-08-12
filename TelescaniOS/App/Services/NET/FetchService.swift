import Foundation
import CryptoKit
import UIKit

final class FetchService {

    static let fetch = FetchService()

    private let session: URLSession

    private let atSymbol = "@"
    private let hashedCode = "hashed_code"
    private let hexFormat = "%02x"

    private init(session: URLSession = .shared) {
        self.session = session
    }

    func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)

        return hashed
            .compactMap {
                String(format: hexFormat, $0)
            }
            .joined()
    }

    private func _fetch<T: Decodable>(
        url: URL,
        method: String = HTTPMethods.get.rawValue,
        queryItems: [URLQueryItem]? = nil,
        headers: [String: String]? = nil,
        body: Data? = nil
    ) async throws -> T {
        var components = URLComponents(
            string: url.absoluteString
        )

        if let queryItems {
            components?.queryItems = queryItems
        }

        guard let finalURL = components?.url else {
            throw URLError(.badURL)
        }

        let isGetRequest = method == HTTPMethods.get.rawValue

        var request = URLRequest(
            url: finalURL,
            cachePolicy: isGetRequest
                ? .reloadIgnoringLocalCacheData
                : .useProtocolCachePolicy,
            timeoutInterval: 15
        )

        request.httpMethod = method

        if isGetRequest {
            request.setValue(
                "no-cache",
                forHTTPHeaderField: "Cache-Control"
            )

            request.setValue(
                "no-cache",
                forHTTPHeaderField: "Pragma"
            )
        }

        if let headers {
            for (key, value) in headers {
                request.setValue(
                    value,
                    forHTTPHeaderField: key
                )
            }
        }

        if let body, !isGetRequest {
            request.httpBody = body
        }

        let (data, response) = try await session.data(
            for: request
        )

        guard let httpResponse =
                response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(
            httpResponse.statusCode
        ) else {
            if let responseText = String(
                data: data,
                encoding: .utf8
            ) {
                print(
                    "Server response error:",
                    responseText
                )
            }

            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(
            T.self,
            from: data
        )
    }

    func fetchUserDataByHashedCode(
        for code: String
    ) async throws -> GetUserDataByHashedCodeResponse {
        let hashedCodeData = sha256(code)

        var components = URLComponents(
            string: Links.telescanApiTunnel
        )

        components?.queryItems = [
            URLQueryItem(
                name: hashedCode,
                value: hashedCodeData
            )
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let json: GetUserDataByHashedCodeResponse =
            try await _fetch(
                url: url,
                method: HTTPMethods.get.rawValue
            )

        return GetUserDataByHashedCodeResponse(
            tgId: json.tgId,
            tgName: json.tgName,
            tgUsername: json.tgUsername.map {
                atSymbol + $0
            },
            photoS3URL: json.photoS3URL,
            hashedCode: hashedCodeData
        )
    }

    func fetchUserDataByTGID(
        for tgID: Int
    ) async throws -> GetUserDataByTGID {
        var components = URLComponents(
            string: Links.telescanApiGetuser
        )

        components?.queryItems = [
            URLQueryItem(
                name: Keys.tgIdKey.rawValue,
                value: String(tgID)
            )
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let json: GetUserDataByHashedCodeResponse =
            try await _fetch(
                url: url,
                method: HTTPMethods.get.rawValue
            )

        return GetUserDataByTGID(
            tgName: json.tgName,
            tgUsername: json.tgUsername.map {
                atSymbol + $0
            },
            photoS3URL: json.photoS3URL
        )
    }

    func updateProfileImage(
        tgID: Int,
        image: UIImage
    ) async throws -> String {
        guard let imageData = image.jpegData(
            compressionQuality: 0.9
        ) else {
            throw NSError(
                domain: "encode_error",
                code: 0
            )
        }

        let requestBody = UploadProfileImageRequest(
            tgId: tgID,
            img: imageData.base64EncodedString()
        )

        let bodyData = try JSONEncoder().encode(
            requestBody
        )

        guard let url = URL(
            string: Links.telescanApiUpdatePhoto
        ) else {
            throw URLError(.badURL)
        }

        let decoded: UploadProfileImageResponse =
            try await _fetch(
                url: url,
                method: HTTPMethods.post.rawValue,
                headers: [
                    "Content-Type": "application/json"
                ],
                body: bodyData
            )

        guard let photoURL = decoded.photoS3URL else {
            throw URLError(.cannotParseResponse)
        }

        return photoURL
    }

    func deleteProfileImage(
        tgID: Int
    ) async throws {
        let requestBody = UpdateUserPhotoRequestByTGID(
            tgId: tgID,
            img: nil
        )

        let bodyData = try JSONEncoder().encode(
            requestBody
        )

        guard let url = URL(
            string: Links.telescanApiUpdatePhoto
        ) else {
            throw URLError(.badURL)
        }

        let _: UploadProfileImageResponse =
            try await _fetch(
                url: url,
                method: HTTPMethods.post.rawValue,
                headers: [
                    "Content-Type": "application/json"
                ],
                body: bodyData
            )
    }

    /// Deletes the complete server-side profile.
    /// Backend contract: DELETE /v1/users/ with account credentials.
    func deleteAccount(
        tgID: Int,
        code: String
    ) async throws {
        guard let url = URL(
            string: Links.telescanApiDeleteAccount
        ) else {
            throw URLError(.badURL)
        }

        let requestBody = DeleteAccountRequest(
            tgId: tgID,
            hashedCode: sha256(code)
        )
        let bodyData = try JSONEncoder().encode(requestBody)

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )

        request.httpMethod = HTTPMethods.delete.rawValue
        request.httpBody = bodyData
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "no-cache",
            forHTTPHeaderField: "Cache-Control"
        )

        let (_, response) = try await session.data(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
