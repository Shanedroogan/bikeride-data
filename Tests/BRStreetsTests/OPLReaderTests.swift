@testable import BRBuild
import Foundation
import Testing

@Suite struct OPLReaderTests {
    struct Parsed: Equatable {
        var id: Int64
        var tags: [String: String]
        var nodes: [Int64]
        var lat: [Int32]
        var lon: [Int32]
    }

    private func read(_ text: String, chunkSize: Int) throws -> (ways: [Parsed], missing: Int, count: Int) {
        var reader = OPLReader(DataChunkSource(Data(text.utf8), chunkSize: chunkSize))
        var ways: [Parsed] = []
        try reader.forEachWay { way in
            var tags: [String: String] = [:]
            for tag in way.tags {
                tags[String(decoding: way.key(tag), as: UTF8.self)] = way.decodedValue(tag)
            }
            ways.append(Parsed(id: way.id, tags: tags, nodes: Array(way.nodeIDs), lat: Array(way.latE7), lon: Array(way.lonE7)))
        }
        return (ways, reader.nodesWithoutLocation, reader.wayCount)
    }

    static let sample = """
        n1 v1 dV c0 t2025-01-01T00:00:00Z i0 u Thighway=crossing x-73.9 y40.7
        w5029221 v36 dV c0 t2025-09-19T22:10:53Z i0 u Thighway=primary,name=Boerum%20%Place,note=a%2c%b%3d%c Nn278630910x-73.9892384y40.6909958,n10001064063x-73.9892231y40.6910299\r
        r7 v1 dV c0 t2025-01-01T00:00:00Z i0 u T Mn1@
        w9 Thighway=footway,name=Caf%e9%%20%%1f6b2% Nn1x-74y40.5,n2xy,n3x0.0000001y-0.5
        w10 T Nn4x1.25y2
        """

    @Test(arguments: [1, 2, 7, 64, 1 << 20])
    func parsesWaysAcrossAnyChunking(chunkSize: Int) throws {
        let (ways, missing, count) = try read(Self.sample, chunkSize: chunkSize)
        #expect(count == 3)
        #expect(missing == 1)
        #expect(ways.count == 3)
        #expect(ways[0] == Parsed(
            id: 5029221, tags: ["highway": "primary", "name": "Boerum Place", "note": "a,b=c"],
            nodes: [278630910, 10001064063], lat: [406909958, 406910299], lon: [-739892384, -739892231]
        ))
        #expect(ways[1].tags["name"] == "Café 🚲")
        #expect(ways[1].nodes == [1, 3])
        #expect(ways[1].lat == [405_000_000, -5_000_000])
        #expect(ways[1].lon == [-740_000_000, 1])
        #expect(ways[2] == Parsed(id: 10, tags: [:], nodes: [4], lat: [20_000_000], lon: [12_500_000]))
    }

    @Test func handlesAFinalLineWithoutNewline() throws {
        let (ways, _, _) = try read("w1 Thighway=path Nn1x1y2,n2x3y4", chunkSize: 5)
        #expect(ways.map(\.nodes) == [[1, 2]])
    }

    @Test func rejectsMalformedWayLines() {
        #expect(throws: OPLError.malformedLine(wayCount: 1)) { try read("wx Thighway=path\n", chunkSize: 16) }
        #expect(throws: OPLError.malformedLine(wayCount: 1)) { try read("w1 Nq1x1y1\n", chunkSize: 16) }
    }

    @Test func unescapesOnlyWellFormedEscapes() {
        func unescape(_ text: String) -> String {
            Array(text.utf8).withUnsafeBufferPointer { OPLNumbers.unescape($0) }
        }
        #expect(unescape("100%25%") == "100%")
        #expect(unescape("50% off") == "50% off")
        #expect(unescape("%zz%") == "%zz%")
        #expect(unescape("plain") == "plain")
    }
}
