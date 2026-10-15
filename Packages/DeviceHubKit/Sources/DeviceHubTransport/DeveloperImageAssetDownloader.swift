import Foundation
import CryptoKit

/// Downloads the assets required to provision a developer image on a paired
/// target. Downloading alone does not authorize or mount an image.
public struct DeveloperImageAssetDownloader: Sendable {
    public enum Asset: String, CaseIterable, Sendable {
        case manifest = "BuildManifest.plist"
        case image = "Image.dmg"
        case trustCache = "Image.dmg.trustcache"
        case cryptexInfo = "Image.dmg.cryptex_info"
        case rootHash = "Image.dmg.root_hash"
    }

    public enum DownloadError: Error, Sendable {
        case invalidSource
        case invalidResponse
        case invalidAsset
        case incompatibleTarget
        case integrityMismatch
    }

    /// Immutable metadata must originate from the authenticated target RSD
    /// handshake, not ProcessInfo on the controller.
    public struct Target: Sendable, Equatable {
        public let productType: String
        public let buildVersion: String

        public init(productType: String, buildVersion: String) throws {
            guard !productType.isEmpty, !buildVersion.isEmpty,
                  productType.utf8.count <= 128,
                  buildVersion.utf8.count <= 64 else {
                throw DownloadError.incompatibleTarget
            }
            self.productType = productType
            self.buildVersion = buildVersion
        }
    }

    /// Manifest metadata is supplied by a trusted, build-aware image catalog.
    /// Every asset must have an expected SHA-256 digest before it is accepted.
    public struct ImagePlan: Sendable {
        public let target: Target
        public let sources: [Asset: URL]
        public let sha256: [Asset: String]
        public let requiresCryptex: Bool

        public init(
            target: Target,
            sources: [Asset: URL],
            sha256: [Asset: String],
            requiresCryptex: Bool
        ) throws {
            let required: Set<Asset> = requiresCryptex
                ? [.manifest, .image, .trustCache, .cryptexInfo, .rootHash]
                : [.manifest, .image, .trustCache]
            guard required.isSubset(of: Set(sources.keys)),
                  Set(sources.keys) == Set(sha256.keys),
                  sha256.values.allSatisfy({
                      $0.count == 64 && $0.utf8.allSatisfy {
                          (48...57).contains($0) || (65...70).contains($0)
                              || (97...102).contains($0)
                      }
                  }) else {
                throw DownloadError.invalidAsset
            }
            self.target = target
            self.sources = sources
            self.sha256 = sha256
            self.requiresCryptex = requiresCryptex
        }
    }

    /// A plan is deliberately required: the caller cannot silently select
    /// assets using the controller iPhone's operating system.
    public func download(
        plan: ImagePlan,
        authenticatedTarget: Target,
        into directory: URL,
        session: URLSession = .shared
    ) async throws -> [Asset: URL] {
        guard plan.target == authenticatedTarget else {
            throw DownloadError.incompatibleTarget
        }
        return try await downloadVerified(
            sources: plan.sources,
            sha256: plan.sha256,
            into: directory,
            session: session
        )
    }

    private func downloadVerified(
        sources: [Asset: URL],
        sha256: [Asset: String],
        into directory: URL,
        session: URLSession
    ) async throws -> [Asset: URL] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var result: [Asset: URL] = [:]
        for asset in Asset.allCases where sources[asset] != nil {
            try Task.checkCancellation()
            guard let source = sources[asset], source.scheme == "https",
                  source.host != nil, let expected = sha256[asset] else {
                throw DownloadError.invalidSource
            }
            let (temporary, response) = try await session.download(from: source)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw DownloadError.invalidResponse
            }
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard !data.isEmpty else { throw DownloadError.invalidAsset }
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
                throw DownloadError.integrityMismatch
            }
            let destination = directory.appendingPathComponent(asset.rawValue)
            let staging = directory.appendingPathComponent(asset.rawValue + ".partial")
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.moveItem(at: temporary, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            result[asset] = destination
        }
        return result
    }

    /// Caller must choose and authenticate a compatible source using the
    /// TARGET device's build and image variant, never the controller's OS.
    public func download(
        sources: [Asset: URL],
        into directory: URL,
        session: URLSession = .shared
    ) async throws -> [Asset: URL] {
        guard sources.keys.contains(.manifest),
              sources.keys.contains(.image),
              sources.keys.contains(.trustCache) else {
            throw DownloadError.invalidAsset
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        var result: [Asset: URL] = [:]
        for asset in Asset.allCases where sources[asset] != nil {
            try Task.checkCancellation()
            guard let source = sources[asset], source.scheme == "https",
                  source.host != nil else {
                throw DownloadError.invalidSource
            }
            let (temporary, response) = try await session.download(from: source)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw DownloadError.invalidResponse
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw DownloadError.invalidAsset
            }
            let destination = directory.appendingPathComponent(asset.rawValue)
            let staging = directory.appendingPathComponent(asset.rawValue + ".partial")
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.moveItem(at: temporary, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            result[asset] = destination
        }
        return result
    }
}
