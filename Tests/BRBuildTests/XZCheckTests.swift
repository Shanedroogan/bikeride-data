import BRBuild
import BRCore
import Foundation
import Testing

private let xzAvailable = ProcessToolRunner().locate("xz") != nil

/// A scratch directory removed when the value goes away.
private final class Scratch: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("xzcheck-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes `text` to `name` and compresses it the way the compilers do, returning the `.xz`.
    func compressed(_ name: String, _ text: String) throws -> URL {
        let raw = url.appendingPathComponent(name)
        try Data(text.utf8).write(to: raw)
        let xz = raw.appendingPathExtension("xz")
        try XZ.compress(raw, to: xz, runner: ProcessToolRunner())
        return xz
    }
}

@Suite struct XZCheckTests {
    // MARK: Real xz

    @Test(.enabled(if: xzAvailable, "needs xz on PATH")) func oneStreamOneBlockPasses() throws {
        let scratch = try Scratch()
        let blob = try scratch.compressed("a.bin", "hello world\n")
        #expect(try XZCheck.verify(blob, runner: ProcessToolRunner()) == .init(streams: 1, blocks: 1))
    }

    @Test(.enabled(if: xzAvailable, "needs xz on PATH")) func concatenatedStreamsThrow() throws {
        let scratch = try Scratch()
        let first = try scratch.compressed("a.bin", "hello world\n")
        let second = try scratch.compressed("b.bin", "second stream\n")
        // `cat a.xz b.xz`: valid for xz, but Apple's decoder would stop after the first stream.
        let joined = scratch.url.appendingPathComponent("ab.bin.xz")
        try (Data(contentsOf: first) + Data(contentsOf: second)).write(to: joined)
        #expect(throws: XZCheck.Failure.notOneStreamOneBlock(file: "ab.bin.xz", streams: 2, blocks: 2)) {
            try XZCheck.verify(joined, runner: ProcessToolRunner())
        }
    }

    @Test(.enabled(if: xzAvailable, "needs xz on PATH")) func nonXZFileThrows() throws {
        let scratch = try Scratch()
        let bogus = scratch.url.appendingPathComponent("bogus.xz")
        try Data("not an xz file at all\n".utf8).write(to: bogus)
        #expect(throws: (any Error).self) { try XZCheck.verify(bogus, runner: ProcessToolRunner()) }
    }

    // MARK: Listing parser

    @Test func acceptsTheRobotListingOfOneBlob() throws {
        let listing = "name\ta.xz\nfile\t1\t1\t64\t12\t5.333\tCRC32\t0\ntotals\t1\t1\t64\t12\t5.333\tCRC32\t0\t1\n"
        #expect(try XZCheck.check(listing: listing, file: "a.xz") == .init(streams: 1, blocks: 1))
    }

    @Test func garbageListingThrows() {
        for garbage in ["", "garbage\n", "name\ta.xz\n", "totals\n", "totals\t1\n", "totals\tone\t1\n", "totals\t1\t\n",
                        "totals\t-1\t1\n", "totals\t+1\t1\n", " totals\t1\t1\n",
                        // Two totals lines: ambiguous, so not trusted.
                        "totals\t1\t1\t64\t12\t5.333\tCRC32\t0\t1\ntotals\t1\t1\t64\t12\t5.333\tCRC32\t0\t1\n"] {
            #expect(throws: XZCheck.Failure.unparsableListing(file: "x.xz", output: garbage), "\(garbage.debugDescription)") {
                try XZCheck.check(listing: garbage, file: "x.xz")
            }
        }
    }

    @Test func countsOtherThanOneAndOneThrow() {
        // What `xz` prints for an empty or broken file (the old parser's silent (0, 0)), an empty
        // payload (1 stream, 0 blocks), two concatenated streams, and one stream of two blocks.
        for (streams, blocks) in [(0, 0), (1, 0), (2, 2), (1, 2), (2, 1)] {
            let listing = "totals\t\(streams)\t\(blocks)\t124\t19\t6.526\tCRC32\t0\t1\n"
            #expect(throws: XZCheck.Failure.notOneStreamOneBlock(file: "x.xz", streams: streams, blocks: blocks)) {
                try XZCheck.check(listing: listing, file: "x.xz")
            }
        }
    }
}
