#if os(macOS) || os(Linux)
import BRCore
import Foundation
import Testing

@Suite struct ProcessToolRunnerTests {
    let runner = ProcessToolRunner()

    @Test func locatesToolsOnThePath() {
        #expect(runner.locate("sh") != nil)
        #expect(runner.locate("/bin/sh") == "/bin/sh")
        #expect(runner.locate("bikeride-no-such-tool") == nil)
    }

    @Test func feedsStandardInputAndCollectsOutput() throws {
        let output = try runner.run(executable: "cat", args: [], stdin: Data("hello\nworld".utf8))
        #expect(output == Data("hello\nworld".utf8))
    }

    @Test func reportsExitStatusAndStandardError() {
        #expect(throws: ToolError.failed(executable: "sh", status: 3, stderr: "oops")) {
            try runner.run(executable: "sh", args: ["-c", "echo oops >&2; exit 3"])
        }
    }

    @Test func reportsMissingTools() {
        #expect(throws: ToolError.notFound(executable: "bikeride-no-such-tool")) {
            try runner.run(executable: "bikeride-no-such-tool", args: [])
        }
    }

    @Test func survivesToolsThatFloodStandardError() throws {
        let output = try runner.run(executable: "sh", args: ["-c", "head -c 300000 /dev/zero >&2; echo done"])
        #expect(output == Data("done\n".utf8))
    }

    @Test func streamsLargeOutput() throws {
        let stream = try runner.stream(executable: "sh", args: ["-c", "head -c 3000000 /dev/zero"])
        var total = 0
        while let chunk = try stream.output.read(upToCount: 1 << 16), !chunk.isEmpty {
            total += chunk.count
        }
        try stream.waitUntilExit()
        #expect(total == 3_000_000)
    }

    @Test func streamSurfacesFailureAfterDraining() throws {
        let stream = try runner.stream(executable: "sh", args: ["-c", "echo partial; exit 2"])
        #expect(try stream.output.readToEnd() == Data("partial\n".utf8))
        #expect(throws: ToolError.self) { try stream.waitUntilExit() }
    }

    @Test func streamCanBeAbandoned() throws {
        let stream = try runner.stream(executable: "sh", args: ["-c", "while true; do echo spam; done"])
        _ = try stream.output.read(upToCount: 100)
        stream.terminate()
    }
}
#endif
