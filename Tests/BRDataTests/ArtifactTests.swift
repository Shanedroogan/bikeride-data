import BRCore
import BRData
import Foundation
import Testing

@Suite struct ArtifactHeaderTests {
    let header = ArtifactHeader(
        kind: .stations,
        formatVersion: 3,
        dataVersion: "2026-09-24T07:15:00Z",
        builderSwiftVersion: "6.0",
        builtAgainst: ["streets": String(repeating: "ab", count: 32), "config": String(repeating: "01", count: 32)]
    )

    @Test func roundTrips() throws {
        let payload = Data((0..<37).map { UInt8($0) })
        let file = header.assemble(payload: payload)
        let (decoded, decodedPayload) = try ArtifactHeader.decode(from: file)
        #expect(decoded == header)
        #expect(decodedPayload == payload)
        #expect(file.count - decodedPayload.count == header.encoded(payloadLength: 37).count)
    }

    @Test func layoutMatchesTheDocumentedFixedFields() throws {
        let bytes = Array(header.encoded(payloadLength: 5))
        #expect(bytes.count % 8 == 0)
        #expect(Array(bytes[0..<4]) == Array("BRDA".utf8))
        #expect(Array(bytes[4..<12]) == [1, 0, 2, 0, 3, 0, 0, 0]) // layout 1, kind 2, format 3, reserved
        #expect(UInt32(bytes[12]) | UInt32(bytes[13]) << 8 == UInt32(bytes.count))
        #expect(Array(bytes[16..<24]) == [5, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func isDeterministic() {
        var shuffled = header
        shuffled.builtAgainst = [:]
        for key in header.builtAgainst.keys.sorted().reversed() { shuffled.builtAgainst[key] = header.builtAgainst[key] }
        #expect(shuffled.encoded(payloadLength: 0) == header.encoded(payloadLength: 0))
    }

    @Test func rejectsForeignOrDamagedFiles() {
        let file = header.assemble(payload: Data(repeating: 7, count: 16))
        var badMagic = file
        badMagic[0] = UInt8(ascii: "X")
        #expect(throws: DataFormatError.badMagic) { try ArtifactHeader.decode(from: badMagic) }

        var badKind = file
        badKind[6] = 99
        #expect(throws: DataFormatError.unknownArtifactKind(99)) { try ArtifactHeader.decode(from: badKind) }

        var badLayout = file
        badLayout[4] = 2
        #expect(throws: DataFormatError.unsupportedHeaderLayout(2)) { try ArtifactHeader.decode(from: badLayout) }

        let truncated = file.prefix(file.count - 1)
        #expect(throws: DataFormatError.payloadLengthMismatch(declared: 16, actual: 15)) { try ArtifactHeader.decode(from: truncated) }
        #expect(throws: DataFormatError.self) { try ArtifactHeader.decode(from: file.prefix(10)) }
        #expect(throws: DataFormatError.self) { try ArtifactHeader.decode(from: file + Data([0])) }
    }

    @Test func artifactKindNames() {
        #expect(ArtifactKind.allCases.map(\.name) == [
            "streets", "stations", "tt-subway", "tt-bus", "tt-lirr", "tt-ferry", "links", "flows", "config", "tt-path",
        ])
        #expect(ArtifactKind.allCases.allSatisfy { ArtifactKind(name: $0.name) == $0 })
        #expect(ArtifactKind(name: "tt-path") == .ttPath && ArtifactKind.ttPath.rawValue == 10)
        #expect(ArtifactKind(name: "tt-unknown") == nil)
        #expect(TransitSystem.allCases.map(ArtifactKind.timetable(for:)) == [.ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath])
    }

    /// Every kind is format 1: streets, stations and the five timetables froze on 2026-09-26 (S1),
    /// links, flows and config on 2026-09-27 (M1). Changing a line here is a format decision
    /// (`docs/formats.md`, "Compatibility"), not a test fix.
    @Test func formatVersions() {
        let s1: [ArtifactKind] = [.streets, .stations, .ttSubway, .ttBus, .ttLirr, .ttFerry, .ttPath]
        let m1: [ArtifactKind] = [.links, .flows, .config]
        #expect(Set(s1 + m1) == Set(ArtifactKind.allCases))
        for kind in s1 + m1 {
            #expect(kind.currentFormatVersion == 1 && kind.supportedFormatVersions == [1], "\(kind.name)")
        }
        #expect(ArtifactKind.allCases.allSatisfy { $0.supportedFormatVersions.contains($0.currentFormatVersion) })
    }
}

@Suite struct MappedArtifactTests {
    private func writeArtifact(kind: ArtifactKind, values: [UInt32], to url: URL) throws {
        var payload = BinaryWriter()
        payload.append(string: "payload")
        payload.append(array: values)
        let header = ArtifactHeader(kind: kind, formatVersion: kind.currentFormatVersion, dataVersion: "test",
                                    builderSwiftVersion: BuildInfo.swiftVersion)
        try header.assemble(payload: payload.data).write(to: url)
    }

    @Test func mapsAFileAndViewsItsPayloadInPlace() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("streets.bin")
        let values = (0..<100_000).map { UInt32($0) &* 2_654_435_761 }
        try writeArtifact(kind: .streets, values: values, to: url)

        let artifact = try MappedArtifact(contentsOf: url, expecting: .streets)
        #expect(artifact.kind == .streets)
        #expect(artifact.header.dataVersion == "test")
        var reader = artifact.payloadReader()
        #expect(try reader.readString() == "payload")
        let view = try reader.readArray(of: UInt32.self)
        #expect(view.count == values.count)
        view.withUnsafeBufferPointer { buffer in
            let mapping = artifact.payload.withUnsafeBytes { $0 }
            let start = UnsafeRawPointer(buffer.baseAddress!)
            #expect(start >= mapping.baseAddress! && start < mapping.baseAddress! + mapping.count) // no copy
            #expect(Int(bitPattern: start) % MemoryLayout<UInt32>.alignment == 0)
            #expect(buffer.elementsEqual(values))
        }
    }

    @Test func rejectsTheWrongKind() throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("links.bin")
        try writeArtifact(kind: .links, values: [1], to: url)
        #expect(throws: DataFormatError.kindMismatch(expected: .flows, found: .links)) {
            try MappedArtifact(contentsOf: url, expecting: .flows)
        }
    }

    @Test func datasetHandleIndexesArtifactsByKind() throws {
        let directory = try TemporaryDirectory()
        var files: [ArtifactKind: URL] = [:]
        for kind in [ArtifactKind.streets, .ttSubway] {
            files[kind] = directory.file("\(kind.name).bin")
            try writeArtifact(kind: kind, values: [UInt32(kind.rawValue)], to: files[kind]!)
        }
        let handle = try DatasetHandle(setID: "20260924T071500Z", files: files)
        #expect(handle.setID == "20260924T071500Z")
        #expect(handle[.streets]?.kind == .streets)
        #expect(try handle.require(.ttSubway).kind == .ttSubway)
        #expect(handle[.flows] == nil)
        #expect(throws: DatasetError.missingArtifact(.flows)) { try handle.require(.flows) }

        // Mismatched file → kind is caught at load.
        #expect(throws: DataFormatError.self) {
            try DatasetHandle(setID: "x", files: [.stations: files[.streets]!])
        }
    }

    @Test func datasetHandleIsShareableAcrossTasks() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("config.bin")
        try writeArtifact(kind: .config, values: Array(0..<1000), to: url)
        let handle = try DatasetHandle(setID: "s", files: [.config: url])
        let sums = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var reader = try handle.require(.config).payloadReader()
                    _ = try reader.readString()
                    return try reader.readArray(of: UInt32.self).withUnsafeBufferPointer { $0.reduce(0) { $0 + Int($1) } }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(sums == Array(repeating: 499_500, count: 8))
    }
}
