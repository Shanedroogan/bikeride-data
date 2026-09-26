import Foundation

/// Supplies input in chunks of any size.
public protocol ByteChunkSource {
    /// The next non-empty chunk, or `nil` at end of input.
    mutating func nextChunk() throws -> [UInt8]?
}

/// Serves an in-memory buffer in fixed-size chunks.
public struct DataChunkSource: ByteChunkSource {
    private let data: Data
    private var offset: Int
    public let chunkSize: Int

    public init(_ data: Data, chunkSize: Int = 1 << 16) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.data = data
        self.offset = data.startIndex
        self.chunkSize = chunkSize
    }

    public mutating func nextChunk() -> [UInt8]? {
        guard offset < data.endIndex else { return nil }
        let end = min(offset + chunkSize, data.endIndex)
        defer { offset = end }
        return [UInt8](data[offset..<end])
    }
}

/// Reads a file or pipe (e.g. `unzip -p` output) until end of file.
public struct FileHandleChunkSource: ByteChunkSource {
    public let handle: FileHandle
    public let chunkSize: Int

    public init(_ handle: FileHandle, chunkSize: Int = 1 << 20) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        self.handle = handle
        self.chunkSize = chunkSize
    }

    public mutating func nextChunk() throws -> [UInt8]? {
        guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return nil }
        return [UInt8](data)
    }
}
