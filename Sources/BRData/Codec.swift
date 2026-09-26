import BRCore
import Foundation

/// Decompresses a blob file into a raw artifact file.
///
/// On failure the destination is removed, so a partial file is never left behind. Callers that
/// know the raw size (from the manifest) pass `expectedRawBytes`; a mismatch is an error.
public protocol Codec: Sendable {
    func decompress(from source: URL, to destination: URL, expectedRawBytes: Int?) throws
}

public enum CodecError: Error, Equatable, Sendable {
    case rawByteCountMismatch(expected: Int, actual: Int)
    /// Bytes follow the end of the first compressed stream, e.g. a concatenated second stream.
    case trailingData
    case truncatedInput
    case decoderFailure(String)
    case cannotCreateOutput(path: String)
}

/// Decodes `.xz` files by running `xz -dc`. Used on Linux, where there is no Compression framework.
public struct XZProcessCodec: Codec {
    public let runner: any ToolRunner

    public init(runner: any ToolRunner) {
        self.runner = runner
    }

    public func decompress(from source: URL, to destination: URL, expectedRawBytes: Int?) throws {
        try writeOutputFile(at: destination) { output in
            let tool = try runner.stream(executable: "xz", args: ["-dc", "--", source.path])
            var total = 0
            do {
                while let chunk = try tool.output.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                    total += chunk.count
                }
            } catch {
                tool.terminate()
                throw error
            }
            try tool.waitUntilExit()
            if let expectedRawBytes, expectedRawBytes != total {
                throw CodecError.rawByteCountMismatch(expected: expectedRawBytes, actual: total)
            }
        }
    }
}

/// Creates (or truncates) `url`, passes a handle for writing to `body`, and removes the file
/// if `body` throws.
func writeOutputFile(at url: URL, _ body: (FileHandle) throws -> Void) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CodecError.cannotCreateOutput(path: url.path)
    }
    do {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try body(handle)
        try handle.synchronize()
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}
