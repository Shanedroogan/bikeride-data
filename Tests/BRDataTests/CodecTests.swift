#if os(macOS) || os(Linux)
import BRCore
import BRData
import Foundation
import Testing

private let runner = ProcessToolRunner()
private let xzInstalled = runner.locate("xz") != nil

/// Compresses with the pipeline's exact settings: one stream, one block, CRC32.
private func xzCompress(_ data: Data) throws -> Data {
    try runner.run(executable: "xz", args: ["-6", "-T1", "--check=crc32", "-c"], stdin: data)
}

@Suite(.enabled(if: xzInstalled, "xz is not installed; `brew install xz` or `apt-get install xz-utils`"))
struct CodecTests {
    let raw = sampleBytes(count: 3_000_000, seed: 2026)

    private func codecs() -> [(name: String, codec: any Codec)] {
        var codecs: [(String, any Codec)] = [("xz process", XZProcessCodec(runner: runner))]
        #if canImport(Compression)
        codecs.append(("Apple LZMA", AppleLZMACodec(bufferSize: 64 * 1024)))
        #endif
        return codecs
    }

    @Test func decodesSingleStreamBlobs() throws {
        let directory = try TemporaryDirectory()
        let blob = directory.file("blob.xz")
        try xzCompress(raw).write(to: blob)
        for (name, codec) in codecs() {
            let output = directory.file("\(name).raw")
            try codec.decompress(from: blob, to: output, expectedRawBytes: raw.count)
            #expect(try Data(contentsOf: output) == raw, "\(name)")
            try codec.decompress(from: blob, to: output, expectedRawBytes: nil)
            #expect(try Data(contentsOf: output) == raw, "\(name) without a size")
        }
    }

    @Test func decodesEmptyPayload() throws {
        let directory = try TemporaryDirectory()
        let blob = directory.file("empty.xz")
        try xzCompress(Data()).write(to: blob)
        for (name, codec) in codecs() {
            let output = directory.file("\(name).raw")
            try codec.decompress(from: blob, to: output, expectedRawBytes: 0)
            #expect(try Data(contentsOf: output).isEmpty, "\(name)")
        }
    }

    @Test func rejectsWrongRawSizeAndRemovesOutput() throws {
        let directory = try TemporaryDirectory()
        let blob = directory.file("blob.xz")
        try xzCompress(raw).write(to: blob)
        for (name, codec) in codecs() {
            let output = directory.file("\(name).raw")
            #expect(throws: CodecError.rawByteCountMismatch(expected: raw.count + 1, actual: raw.count), "\(name)") {
                try codec.decompress(from: blob, to: output, expectedRawBytes: raw.count + 1)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path), "\(name) left a partial file")
        }
    }

    @Test func rejectsCorruptAndTruncatedBlobs() throws {
        let directory = try TemporaryDirectory()
        let compressed = try xzCompress(raw)
        var corrupt = compressed
        corrupt[corrupt.count / 2] ^= 0xFF
        try corrupt.write(to: directory.file("corrupt.xz"))
        try compressed.prefix(compressed.count - 64).write(to: directory.file("truncated.xz"))
        for (name, codec) in codecs() {
            for input in ["corrupt.xz", "truncated.xz"] {
                let output = directory.file("\(name)-\(input).raw")
                #expect(throws: (any Error).self, "\(name) accepted \(input)") {
                    try codec.decompress(from: directory.file(input), to: output, expectedRawBytes: raw.count)
                }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    #if canImport(Compression)
    /// Apple's decoder stops after the first of two concatenated streams and reports success.
    /// The raw-size check must turn that silent truncation into an error.
    @Test func appleCodecDetectsConcatenatedStreams() throws {
        let directory = try TemporaryDirectory()
        let first = raw.prefix(1_000_000), second = raw.suffix(from: 1_000_000)
        let blob = directory.file("concatenated.xz")
        try (xzCompress(Data(first)) + xzCompress(Data(second))).write(to: blob)
        let output = directory.file("out.raw")
        let apple = AppleLZMACodec()

        #expect(throws: CodecError.rawByteCountMismatch(expected: raw.count, actual: first.count)) {
            try apple.decompress(from: blob, to: output, expectedRawBytes: raw.count)
        }
        #expect(throws: CodecError.trailingData) {
            try apple.decompress(from: blob, to: output, expectedRawBytes: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // xz itself decodes concatenations, so only the Apple path needs the guard.
        try XZProcessCodec(runner: runner).decompress(from: blob, to: output, expectedRawBytes: raw.count)
        #expect(try Data(contentsOf: output) == raw)
    }
    #endif
}
#endif
