import Foundation

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
