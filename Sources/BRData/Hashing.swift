import BRCore
import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// A SHA-256 digest. Codable as lowercase hex, the form used in manifests and `builtAgainst`.
public struct Digest256: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }

    /// Parses 64 hex digits, either case.
    public init?(hex: some StringProtocol) {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for pair in stride(from: 0, to: 64, by: 2) {
            guard let high = Self.nibble(digits[pair]), let low = Self.nibble(digits[pair + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public var description: String { hex }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension Digest256: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let digest = Digest256(hex: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected 64 hex digits")
        }
        self = digest
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Computes SHA-256 digests. CryptoKit where available, else a system tool.
public protocol Hasher256: Sendable {
    func sha256(of data: Data) throws -> Digest256
    /// Hashes a file without loading it into memory at once.
    func sha256(ofFileAt url: URL) throws -> Digest256
}

#if canImport(CryptoKit)
public struct CryptoKitHasher: Hasher256 {
    public init() {}

    public func sha256(of data: Data) -> Digest256 {
        Self.digest(SHA256.hash(data: data))
    }

    public func sha256(ofFileAt url: URL) throws -> Digest256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Self.digest(hasher.finalize())
    }

    private static func digest(_ digest: SHA256.Digest) -> Digest256 {
        guard let result = Digest256(bytes: Array(digest)) else {
            preconditionFailure("SHA256.Digest is not 32 bytes")
        }
        return result
    }
}
#endif

/// Hashes with `sha256sum` (Linux) or `shasum -a 256` (macOS) through a ``ToolRunner``.
public struct ProcessHasher: Hasher256 {
    public enum Tool: Sendable {
        case sha256sum
        case shasum

        var executable: String {
            switch self {
            case .sha256sum: "sha256sum"
            case .shasum: "shasum"
            }
        }

        var baseArguments: [String] {
            switch self {
            case .sha256sum: []
            case .shasum: ["-a", "256"]
            }
        }
    }

    public enum HashError: Error, Equatable, Sendable {
        case noHashTool
        case unparseableOutput(String)
    }

    public let runner: any ToolRunner
    public let tool: Tool

    /// Uses `tool`, or the first of `sha256sum` and `shasum` that `runner` can locate.
    public init(runner: any ToolRunner, tool: Tool? = nil) throws {
        self.runner = runner
        if let tool {
            self.tool = tool
        } else if runner.locate(Tool.sha256sum.executable) != nil {
            self.tool = .sha256sum
        } else if runner.locate(Tool.shasum.executable) != nil {
            self.tool = .shasum
        } else {
            throw HashError.noHashTool
        }
    }

    public func sha256(of data: Data) throws -> Digest256 {
        try parse(runner.run(executable: tool.executable, args: tool.baseArguments, stdin: data))
    }

    public func sha256(ofFileAt url: URL) throws -> Digest256 {
        try parse(runner.run(executable: tool.executable, args: tool.baseArguments + [url.path], stdin: nil))
    }

    /// Output is `<hex>  <name>`; both tools prefix a backslash when the name needed escaping.
    private func parse(_ output: Data) throws -> Digest256 {
        let text = String(decoding: output, as: UTF8.self)
        let hex = text.drop { $0 == "\\" }.prefix(64)
        guard let digest = Digest256(hex: hex) else { throw HashError.unparseableOutput(text) }
        return digest
    }
}
