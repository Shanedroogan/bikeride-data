import BRCore
import BRData
import Foundation
import Testing

/// Tier A, named by the M1 exit: a blob compressed on Linux decodes with Apple's one-stream LZMA.
///
/// `Tests/Fixtures/xz/noble-xz-5.4.5/tt-sample.bin.xz` was made in the `swift:6.4-noble` container
/// (xz-utils 5.4.5, the version Ubuntu 24.04 CI runs) with the pipeline's exact flags,
/// `xz -6 -T1 --check=crc32`, from the committed `Tests/Fixtures/v1/tt-sample.bin`. The Mac's xz
/// (5.8.4 when it was made) wrote the same bytes.
///
/// - With the Compression framework: ``AppleLZMACodec`` must decode the Linux blob to exactly the
///   committed raw file, which is what the phone does with every published blob.
/// - Elsewhere (Linux CI): re-compressing the raw file must give exactly the committed blob, so an
///   xz upgrade on the build runners that changes the bytes fails here rather than silently
///   changing every blob sha.
///
/// If `tt-sample.bin` is rewritten on purpose (`BR_WRITE_V1_FIXTURES`), remake the blob:
/// `container run --rm -v "$PWD":/work swift:6.4-noble sh -c 'apt-get update && apt-get install -y
/// xz-utils && cd /work && xz -6 -T1 --check=crc32 -c tt-sample.bin > tt-sample.bin.xz'`.
@Suite struct LinuxXZTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let raw = fixtures.appendingPathComponent("v1/tt-sample.bin")
    static let linuxBlob = fixtures.appendingPathComponent("xz/noble-xz-5.4.5/tt-sample.bin.xz")

    static let runner = ProcessToolRunner()
    static let xzInstalled = runner.locate("xz") != nil

    @Test func committedFilesArePresent() throws {
        #expect(try Data(contentsOf: Self.raw).count == 2688)
        #expect(try Data(contentsOf: Self.linuxBlob).count == 644)
    }

    #if canImport(Compression)
    @Test func appleLZMADecodesTheLinuxMadeBlob() throws {
        let raw = try Data(contentsOf: Self.raw)
        let directory = try TemporaryDirectory()
        let output = directory.file("tt-sample.bin")
        try AppleLZMACodec().decompress(from: Self.linuxBlob, to: output, expectedRawBytes: raw.count)
        #expect(try Data(contentsOf: output) == raw)
    }
    #endif

    /// Required on Linux; on the Mac it runs when xz is installed and checks the Mac's xz writes the
    /// same bytes as Linux's (the premise of building on either).
    @Test(.enabled(if: xzInstalled || !Self.hasCompressionFramework, "xz is not installed"))
    func pipelineXZReproducesTheLinuxBlob() throws {
        let raw = try Data(contentsOf: Self.raw)
        let compressed = try Self.runner.run(executable: "xz", args: ["-6", "-T1", "--check=crc32", "-c"], stdin: raw)
        let version = (try? Self.runner.run(executable: "xz", args: ["--version"])).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        #expect(compressed == (try Data(contentsOf: Self.linuxBlob)),
                "this xz (\(version.split(separator: "\n").first ?? "")) no longer writes the committed noble-xz-5.4.5 bytes")
    }

    static var hasCompressionFramework: Bool {
        #if canImport(Compression)
        true
        #else
        false
        #endif
    }
}
