import Foundation

/// `--name value` and `--flag` arguments for the stations, links and all commands.
struct CommandOptions {
    struct UsageError: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []

    init(_ arguments: [String], valued: Set<String>, flags known: Set<String>) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valued.contains(argument) {
                guard index + 1 < arguments.count else { throw UsageError(description: "\(argument) needs a value") }
                values[argument] = arguments[index + 1]
                index += 2
            } else if known.contains(argument) {
                flags.insert(argument)
                index += 1
            } else {
                throw UsageError(description: "unknown argument '\(argument)'")
            }
        }
    }

    func url(_ name: String, default path: String) -> URL {
        Self.absoluteURL(values[name] ?? path)
    }

    func int(_ name: String) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text), value > 0 else { throw UsageError(description: "\(name) needs a positive integer") }
        return value
    }

    static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
    }
}

/// Writes one line to standard error.
func logLine(_ prefix: String, _ message: String) {
    FileHandle.standardError.write(Data("\(prefix): \(message)\n".utf8))
}
