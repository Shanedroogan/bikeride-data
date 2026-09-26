#if canImport(Compression)
import Compression
import Foundation

/// Decodes single-stream `.xz` files with the Compression framework's streaming LZMA decoder.
///
/// Apple's decoder stops at the end of the first xz stream and reports success, silently
/// dropping any concatenated streams. Blobs are published as exactly one stream, and this codec
/// refuses anything else: the output size must equal `expectedRawBytes` when given, and any
/// input left after the first stream is ``CodecError/trailingData``.
public struct AppleLZMACodec: Codec {
    public let bufferSize: Int

    public init(bufferSize: Int = 1 << 20) {
        precondition(bufferSize > 0, "bufferSize must be positive")
        self.bufferSize = bufferSize
    }

    public func decompress(from source: URL, to destination: URL, expectedRawBytes: Int?) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try writeOutputFile(at: destination) { output in
            let result = try decode(input, into: output)
            if let expectedRawBytes, expectedRawBytes != result.bytesWritten {
                throw CodecError.rawByteCountMismatch(expected: expectedRawBytes, actual: result.bytesWritten)
            }
            if result.hasTrailingInput { throw CodecError.trailingData }
        }
    }

    /// Streams `input` through the decoder until the end of the first xz stream.
    private func decode(_ input: FileHandle, into output: FileHandle) throws -> (bytesWritten: Int, hasTrailingInput: Bool) {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw CodecError.decoderFailure("compression_stream_init failed")
        }
        defer { compression_stream_destroy(stream) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { source.deallocate() }
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        stream.pointee.src_ptr = UnsafePointer(source)
        stream.pointee.src_size = 0
        var inputExhausted = false
        var total = 0

        while true {
            if stream.pointee.src_size == 0 && !inputExhausted {
                let chunk = try input.read(upToCount: bufferSize) ?? Data()
                if chunk.isEmpty {
                    inputExhausted = true
                } else {
                    chunk.copyBytes(to: source, count: chunk.count)
                    stream.pointee.src_ptr = UnsafePointer(source)
                    stream.pointee.src_size = chunk.count
                }
            }
            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = bufferSize
            let flags = inputExhausted ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw CodecError.decoderFailure("corrupt or unsupported xz data")
            }

            let produced = bufferSize - stream.pointee.dst_size
            if produced > 0 {
                try output.write(contentsOf: Data(bytesNoCopy: destination, count: produced, deallocator: .none))
                total += produced
            }
            if status == COMPRESSION_STATUS_END {
                if stream.pointee.src_size > 0 { return (total, true) }
                let next = try input.read(upToCount: 1) ?? Data()
                return (total, !next.isEmpty)
            }
            if inputExhausted && produced == 0 && stream.pointee.src_size == 0 {
                throw CodecError.truncatedInput
            }
        }
    }
}
#endif
