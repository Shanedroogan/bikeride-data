/// Maps column names from a header record to field indices.
public struct CSVHeader: Sendable {
    public let names: [String]
    private let indices: [String: Int]

    /// Names are trimmed of surrounding spaces and tabs. If a name repeats, the first column wins.
    public init(_ record: CSVRecord) {
        self.init(names: record.fields.map(\.string))
    }

    public init(names: [String]) {
        let trimmed = names.map { $0.trimmingASCIIBlanks() }
        self.names = trimmed
        var indices: [String: Int] = [:]
        for (index, name) in trimmed.enumerated() where indices[name] == nil {
            indices[name] = index
        }
        self.indices = indices
    }

    public func index(of name: String) -> Int? {
        indices[name]
    }

    public func requireIndex(of name: String) throws -> Int {
        guard let index = indices[name] else { throw CSVError.missingColumn(name) }
        return index
    }
}

extension String {
    fileprivate func trimmingASCIIBlanks() -> String {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let first = firstIndex(where: { !isBlank($0) }), let last = lastIndex(where: { !isBlank($0) }) else {
            return ""
        }
        return String(self[first...last])
    }
}
