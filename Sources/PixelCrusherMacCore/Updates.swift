import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SemanticVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let preReleaseIdentifiers: [String]

    public init(major: Int, minor: Int, patch: Int, preReleaseIdentifiers: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.preReleaseIdentifiers = preReleaseIdentifiers
    }

    public init?(parsing rawValue: String) {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }

        if candidate.hasPrefix("v") || candidate.hasPrefix("V") {
            candidate.removeFirst()
        }

        if let plusIndex = candidate.firstIndex(of: "+") {
            candidate = String(candidate[..<plusIndex])
        }

        let components = candidate.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberPart = String(components[0])
        let numberComponents = numberPart.split(separator: ".", omittingEmptySubsequences: false)

        guard (1...3).contains(numberComponents.count) else {
            return nil
        }

        guard let major = Int(numberComponents[0]) else { return nil }
        let minor = numberComponents.count > 1 ? Int(numberComponents[1]) : 0
        let patch = numberComponents.count > 2 ? Int(numberComponents[2]) : 0

        guard let minor, let patch else { return nil }

        let preReleaseIdentifiers: [String]
        if components.count > 1 {
            preReleaseIdentifiers = components[1]
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
        } else {
            preReleaseIdentifiers = []
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            preReleaseIdentifiers: preReleaseIdentifiers
        )
    }

    public var description: String {
        var output = "\(major).\(minor).\(patch)"
        if !preReleaseIdentifiers.isEmpty {
            output += "-\(preReleaseIdentifiers.joined(separator: "."))"
        }
        return output
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.preReleaseIdentifiers.isEmpty, rhs.preReleaseIdentifiers.isEmpty) {
        case (true, true):
            return false
        case (true, false):
            return false
        case (false, true):
            return true
        case (false, false):
            return comparePreRelease(lhs.preReleaseIdentifiers, rhs.preReleaseIdentifiers) == .orderedAscending
        }
    }

    private static func comparePreRelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : nil
            let right = index < rhs.count ? rhs[index] : nil

            switch (left, right) {
            case (nil, nil):
                return .orderedSame
            case (nil, _):
                return .orderedAscending
            case (_, nil):
                return .orderedDescending
            case let (left?, right?):
                if left == right {
                    continue
                }

                let leftNumeric = Int(left)
                let rightNumeric = Int(right)

                switch (leftNumeric, rightNumeric) {
                case let (leftNumeric?, rightNumeric?):
                    if leftNumeric < rightNumeric { return .orderedAscending }
                    if leftNumeric > rightNumeric { return .orderedDescending }
                case (_?, nil):
                    return .orderedAscending
                case (nil, _?):
                    return .orderedDescending
                case (nil, nil):
                    let comparison = left.compare(right, options: .numeric)
                    if comparison != .orderedSame {
                        return comparison
                    }
                }
            }
        }

        return .orderedSame
    }
}

public struct GitHubReleaseAsset: Decodable, Sendable, Hashable {
    public let name: String
    public let browserDownloadURL: URL
    public let contentType: String?
    public let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
        case digest
    }
}

public enum ReleaseAssetPlatform: Sendable {
    case macOS
    case windows
    case linux
    case any
}

public struct GitHubRelease: Decodable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }

    public var semanticVersion: SemanticVersion? {
        SemanticVersion(parsing: tagName)
    }

    public func preferredAsset(for platform: ReleaseAssetPlatform = .macOS) -> GitHubReleaseAsset? {
        let rankedExtensions: [String]
        switch platform {
        case .macOS:
            // Prefer ZIP for in-place updater flow (no mount required).
            rankedExtensions = ["zip", "dmg", "pkg"]
        case .windows:
            rankedExtensions = ["msi", "exe"]
        case .linux:
            rankedExtensions = ["appimage", "deb"]
        case .any:
            rankedExtensions = ["zip", "dmg", "pkg", "msi", "exe", "appimage", "deb"]
        }

        for expectedExtension in rankedExtensions {
            if let asset = assets.first(where: {
                $0.name.lowercased().hasSuffix(".\(expectedExtension)")
            }) {
                return asset
            }
        }

        return nil
    }

    public func preferredAssetURL(for platform: ReleaseAssetPlatform = .macOS) -> URL? {
        preferredAsset(for: platform)?.browserDownloadURL
    }
}

public struct UpdateCheckResult: Sendable {
    public let currentVersion: SemanticVersion
    public let latestVersion: SemanticVersion
    public let release: GitHubRelease
    public let preferredAsset: GitHubReleaseAsset?
    public let downloadURL: URL?

    public init(
        currentVersion: SemanticVersion,
        latestVersion: SemanticVersion,
        release: GitHubRelease,
        preferredAsset: GitHubReleaseAsset?,
        downloadURL: URL?
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.release = release
        self.preferredAsset = preferredAsset
        self.downloadURL = downloadURL
    }

    public var isUpdateAvailable: Bool {
        latestVersion > currentVersion
    }
}

public enum GitHubReleaseClientError: LocalizedError {
    case invalidResponse
    case notFoundLatestRelease(owner: String, repo: String)
    case unauthorizedOrForbidden(statusCode: Int)
    case rateLimited
    case httpError(statusCode: Int, body: String)
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub API returned an invalid response."
        case .notFoundLatestRelease(let owner, let repo):
            return "GitHub API /releases/latest returned 404 for \(owner)/\(repo). This usually means there is no published release yet, or the repository is private and needs a token."
        case .unauthorizedOrForbidden(let statusCode):
            return "GitHub API request failed with status \(statusCode). If this repository is private, configure a GitHub token (PIXELCRUSHER_GITHUB_TOKEN or defaults key PixelCrusherGitHubToken)."
        case .rateLimited:
            return "GitHub API rate limit reached. Please try again later or set a GitHub token."
        case .httpError(let statusCode, let body):
            if body.isEmpty {
                return "GitHub API request failed with status \(statusCode)."
            }
            return "GitHub API request failed with status \(statusCode): \(body)"
        case .decodeFailed:
            return "Failed to parse GitHub release payload."
        }
    }
}

public struct GitHubReleaseClient: Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let authToken: String?

    public init(
        session: URLSession = .shared,
        decoder: JSONDecoder = JSONDecoder(),
        authToken: String? = nil
    ) {
        self.session = session
        self.decoder = decoder
        self.authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        let endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw GitHubReleaseClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PixelCrusher-UpdateCheck", forHTTPHeaderField: "User-Agent")

        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubReleaseClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            switch httpResponse.statusCode {
            case 401, 403:
                throw GitHubReleaseClientError.unauthorizedOrForbidden(statusCode: httpResponse.statusCode)
            case 404:
                throw GitHubReleaseClientError.notFoundLatestRelease(owner: owner, repo: repo)
            case 429:
                throw GitHubReleaseClientError.rateLimited
            default:
                let responseText = String(data: data, encoding: .utf8) ?? ""
                throw GitHubReleaseClientError.httpError(statusCode: httpResponse.statusCode, body: responseText)
            }
        }

        do {
            return try decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw GitHubReleaseClientError.decodeFailed
        }
    }
}

public enum UpdateCheckError: LocalizedError {
    case invalidCurrentVersion(String)
    case invalidReleaseTag(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let value):
            return "Current app version is not semantic: \(value)"
        case .invalidReleaseTag(let value):
            return "Latest GitHub release tag is not semantic: \(value)"
        }
    }
}

public struct GitHubReleaseUpdateChecker: Sendable {
    public let owner: String
    public let repo: String
    public let client: GitHubReleaseClient

    public init(
        owner: String,
        repo: String,
        client: GitHubReleaseClient = GitHubReleaseClient()
    ) {
        self.owner = owner
        self.repo = repo
        self.client = client
    }

    public func checkForUpdate(currentVersionString: String, platform: ReleaseAssetPlatform = .macOS) async throws -> UpdateCheckResult {
        guard let currentVersion = SemanticVersion(parsing: currentVersionString) else {
            throw UpdateCheckError.invalidCurrentVersion(currentVersionString)
        }

        let release = try await client.fetchLatestRelease(owner: owner, repo: repo)

        guard let latestVersion = release.semanticVersion else {
            throw UpdateCheckError.invalidReleaseTag(release.tagName)
        }

        let preferredAsset = release.preferredAsset(for: platform)
        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            release: release,
            preferredAsset: preferredAsset,
            downloadURL: preferredAsset?.browserDownloadURL ?? release.htmlURL
        )
    }
}

public enum GitHubTokenResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> String? {
        let candidates: [String?] = [
            environment["PIXELCRUSHER_GITHUB_TOKEN"],
            environment["GITHUB_TOKEN"],
            defaults.string(forKey: "PixelCrusherGitHubToken")
        ]

        for candidate in candidates {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                continue
            }
            return raw
        }

        return nil
    }
}
