import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs external command-line tools (`unzip`, `osmium`, `xz`, `sha256sum`, …).
///
/// Everything that shells out goes through this protocol, so tests can substitute fakes or
/// point at tiny fixtures.
public protocol ToolRunner: Sendable {
    /// The resolved path of `executable`, or `nil` if it is not installed.
    func locate(_ executable: String) -> String?

    /// Runs a tool to completion and returns its standard output.
    /// Throws ``ToolError`` if the tool is missing or exits unsuccessfully.
    func run(executable: String, args: [String], stdin: Data?) throws -> Data

    /// Starts a tool whose standard output is consumed incrementally, optionally feeding
    /// `stdinFile` to its standard input.
    func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream
}

extension ToolRunner {
    public func run(executable: String, args: [String]) throws -> Data {
        try run(executable: executable, args: args, stdin: nil)
    }

    public func stream(executable: String, args: [String]) throws -> ToolStream {
        try stream(executable: executable, args: args, stdinFile: nil)
    }
}

/// A running tool. Read ``output`` to end of file, then call ``waitUntilExit()`` to learn
/// whether the tool succeeded. Waiting before draining can deadlock on a full pipe; call
/// ``terminate()`` to abandon a stream early.
public struct ToolStream {
    public let output: FileHandle
    private let wait: () throws -> Void
    private let kill: () -> Void

    public init(output: FileHandle, waitUntilExit: @escaping () throws -> Void, terminate: @escaping () -> Void) {
        self.output = output
        self.wait = waitUntilExit
        self.kill = terminate
    }

    public func waitUntilExit() throws {
        try wait()
    }

    public func terminate() {
        kill()
    }
}

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case notFound(executable: String)
    case failed(executable: String, status: Int32, stderr: String)
    case killed(executable: String, signal: Int32)

    public var description: String {
        switch self {
        case .notFound(let executable):
            "\(executable): not found on PATH"
        case .failed(let executable, let status, let stderr):
            "\(executable) exited with status \(status)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case .killed(let executable, let signal):
            "\(executable) was killed by signal \(signal)"
        }
    }
}

#if os(macOS) || os(Linux)

/// Runs tools with `Foundation.Process`.
///
/// Standard error goes to a scratch file rather than a pipe, and standard input comes from a
/// file, so a chatty tool can never deadlock against a reader that is busy with standard output.
public struct ProcessToolRunner: ToolRunner {
    /// Searched after `PATH`, which is often minimal under IDEs and CI.
    public static let fallbackSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public let searchPaths: [String]

    public init(searchPaths: [String]? = nil) {
        if let searchPaths {
            self.searchPaths = searchPaths
        } else {
            let fromEnvironment = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
            var seen = Set<String>()
            self.searchPaths = (fromEnvironment + Self.fallbackSearchPaths).filter { seen.insert($0).inserted }
        }
    }

    public func locate(_ executable: String) -> String? {
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }
        return searchPaths.lazy
            .map { $0.hasSuffix("/") ? $0 + executable : $0 + "/" + executable }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func run(executable: String, args: [String], stdin: Data?) throws -> Data {
        let stdinFile = try stdin.map { try ScratchFile(contents: $0) }
        defer { stdinFile?.remove() }
        let launched = try launch(executable, args, stdinFile: stdinFile?.url)
        let output: Data
        do {
            output = try launched.stdout.readToEnd() ?? Data()
        } catch {
            launched.terminate()
            throw error
        }
        try launched.finish()
        return output
    }

    public func stream(executable: String, args: [String], stdinFile: URL?) throws -> ToolStream {
        let launched = try launch(executable, args, stdinFile: stdinFile)
        return ToolStream(output: launched.stdout, waitUntilExit: launched.finish, terminate: launched.terminate)
    }

    private struct Launched {
        let stdout: FileHandle
        let finish: () throws -> Void
        let terminate: () -> Void
    }

    private func launch(_ executable: String, _ args: [String], stdinFile: URL?) throws -> Launched {
        guard let path = locate(executable) else { throw ToolError.notFound(executable: executable) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let stdinHandle = try stdinFile.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let stderrFile = try ScratchFile()
        let stderrHandle = try FileHandle(forWritingTo: stderrFile.url)
        let stdoutPipe = Pipe()
        process.standardInput = stdinHandle
        process.standardOutput = stdoutPipe
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdinHandle.close()
            try? stderrHandle.close()
            stderrFile.remove()
            throw error
        }
        // The child owns its copy of the pipe's write end now. Close the parent's copy, or
        // reads never see end-of-file: Linux Foundation does not close it after spawning.
        try? stdoutPipe.fileHandleForWriting.close()

        let finish: () throws -> Void = {
            process.waitUntilExit()
            try? stdinHandle.close()
            try? stderrHandle.close()
            let stderr = stderrFile.readTail(maxBytes: 16 * 1024)
            stderrFile.remove()
            switch (process.terminationReason, process.terminationStatus) {
            case (.exit, 0):
                return
            case (.exit, let status):
                throw ToolError.failed(executable: executable, status: status, stderr: stderr)
            case (_, let signal):
                throw ToolError.killed(executable: executable, signal: signal)
            }
        }
        let terminate: () -> Void = {
            // Stop reading first so a tool blocked on a full pipe gets SIGPIPE, then ask it to
            // stop, and kill it if it hasn't exited within 2 s. Linux Foundation can otherwise
            // wait forever on a tool that is still writing.
            try? stdoutPipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? finish()
        }
        return Launched(stdout: stdoutPipe.fileHandleForReading, finish: finish, terminate: terminate)
    }
}

/// A uniquely named file in the temporary directory, removed explicitly by its owner.
private struct ScratchFile {
    let url: URL

    init(contents: Data = Data()) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bikeride-tool-\(UUID().uuidString)")
        try contents.write(to: url)
    }

    func readTail(maxBytes: Int) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
