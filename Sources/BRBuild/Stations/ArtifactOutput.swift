import BRCore
import BRData
import Foundation

/// What the stations and links compilers record about an artifact they wrote.
public struct BuiltArtifactInfo: Codable, Sendable, Equatable {
    public var path: String
    public var rawBytes: Int
    public var rawSha256: String
    public var xzPath: String?
    public var xzBytes: Int?
    public var xzStreams: Int?
    public var xzBlocks: Int?
    public var formatVersion: Int
    public var draftRevision: Int
    public var dataVersion: String
    public var builtAgainst: [String: String]
}

/// Writing a raw artifact and its one-stream `.xz` blob.
enum ArtifactOutput {
    /// Writes `bytes` atomically to `url`, hashes it, and with `compress` runs
    /// `xz -6 -T1 --check=crc32` and records the stream and block counts.
    static func write(
        _ bytes: Data, to url: URL, compress: Bool, runner: any ToolRunner,
        formatVersion: UInt16, draftRevision: UInt32, dataVersion: String, builtAgainst: [String: String],
        seconds: inout [String: Double]
    ) throws -> BuiltArtifactInfo {
        func timed<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer { seconds[phase, default: 0] += Date().timeIntervalSince(start) }
            return try body()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try timed("write") { try bytes.write(to: url, options: .atomic) }
        let sha = try timed("hash") { try sha256(ofFileAt: url, runner: runner) }
        var info = BuiltArtifactInfo(
            path: url.path, rawBytes: bytes.count, rawSha256: sha, formatVersion: Int(formatVersion),
            draftRevision: Int(draftRevision), dataVersion: dataVersion, builtAgainst: builtAgainst
        )
        if compress {
            try timed("xz") {
                let xzURL = url.appendingPathExtension("xz")
                try XZ.compress(url, to: xzURL, runner: runner)
                let listing = try XZ.list(xzURL, runner: runner)
                info.xzPath = xzURL.path
                info.xzBytes = (try FileManager.default.attributesOfItem(atPath: xzURL.path)[.size] as? NSNumber)?.intValue
                info.xzStreams = listing.streams
                info.xzBlocks = listing.blocks
            }
        }
        return info
    }

    static func sha256(ofFileAt url: URL, runner: any ToolRunner) throws -> String {
        #if canImport(CryptoKit)
        return try CryptoKitHasher().sha256(ofFileAt: url).hex
        #else
        return try ProcessHasher(runner: runner).sha256(ofFileAt: url).hex
        #endif
    }
}
