import BRCore
import Foundation

/// The check every `.xz` blob must pass: exactly one stream holding exactly one block.
///
/// Apple's LZMA decoder stops after the first stream and reports success, so a blob with a second
/// stream would silently decode short on the phone (`docs/formats.md`, "Integrity and
/// compression"). Every compiler runs this right after compressing, and the publish gate runs it
/// again. Anything else fails: a listing that does not parse is an error, never "0 streams".
public enum XZCheck {
    /// Stream and block counts from the `totals` line of `xz --robot --list`.
    public struct Listing: Sendable, Equatable {
        public var streams: Int
        public var blocks: Int

        public init(streams: Int, blocks: Int) {
            self.streams = streams
            self.blocks = blocks
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The output has no single `totals` line with integer stream and block counts.
        case unparsableListing(file: String, output: String)
        /// The blob parses but is not exactly one stream with one block.
        case notOneStreamOneBlock(file: String, streams: Int, blocks: Int)

        public var description: String {
            switch self {
            case .unparsableListing(let file, let output):
                let excerpt = output.count > 200 ? String(output.prefix(200)) + "…" : output
                return "\(file): `xz --robot --list` output has no parsable totals line: \(excerpt.debugDescription)"
            case .notOneStreamOneBlock(let file, let streams, let blocks):
                return "\(file): \(streams) xz stream(s) and \(blocks) block(s); a blob must be exactly 1 stream with 1 block"
            }
        }
    }

    /// Runs `xz --robot --list` on `file` and returns its counts, throwing unless the listing
    /// parses and shows exactly 1 stream and 1 block. A listing `xz` itself rejects (not an xz
    /// file, truncated, empty) throws the runner's `ToolError`.
    @discardableResult
    public static func verify(_ file: URL, runner: any ToolRunner) throws -> Listing {
        let output = try runner.run(executable: "xz", args: ["--robot", "--list", "--", file.path])
        return try check(listing: String(decoding: output, as: UTF8.self), file: file.lastPathComponent)
    }

    /// Parses one file's `xz --robot --list` output and requires exactly 1 stream and 1 block.
    @discardableResult
    public static func check(listing output: String, file: String) throws -> Listing {
        let listing = try parse(listing: output, file: file)
        guard listing.streams == 1, listing.blocks == 1 else {
            throw Failure.notOneStreamOneBlock(file: file, streams: listing.streams, blocks: listing.blocks)
        }
        return listing
    }

    /// The counts on the single `totals` line: `totals <streams> <blocks> <compressed> …`,
    /// tab-separated. Throws ``Failure/unparsableListing(file:output:)`` when there is no such
    /// line, more than one, or its counts are not non-negative integers.
    public static func parse(listing output: String, file: String) throws -> Listing {
        let totals = output.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            .filter { $0.first == "totals" }
        guard totals.count == 1, totals[0].count > 2,
              let streams = count(totals[0][1]), let blocks = count(totals[0][2])
        else { throw Failure.unparsableListing(file: file, output: output) }
        return Listing(streams: streams, blocks: blocks)
    }

    /// A count as `xz` prints it: ASCII digits only.
    private static func count(_ field: Substring) -> Int? {
        guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return nil
        }
        return Int(field)
    }
}
