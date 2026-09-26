import BRBuild
import BRCore
import Foundation
import Testing

/// Parses `text` fully, returning each record's fields as strings.
private func parse(_ text: String, chunkSize: Int = 1 << 16) throws -> [[String]] {
    try parse(Array(text.utf8), chunkSize: chunkSize)
}

private func parse(_ bytes: [UInt8], chunkSize: Int) throws -> [[String]] {
    var reader = CSVReader(bytes: bytes, chunkSize: chunkSize)
    var records: [[String]] = []
    while let record = try reader.next() {
        records.append(record.fields.map(\.string))
    }
    return records
}

@Suite struct CSVReaderTests {
    @Test func readsPlainRecords() throws {
        #expect(try parse("a,b,c\n1,2,3\n") == [["a", "b", "c"], ["1", "2", "3"]])
        #expect(try parse("a,b\n1,2") == [["a", "b"], ["1", "2"]])
        #expect(try parse("") == [])
        #expect(try parse("\n\n") == [])
    }

    @Test func keepsEmptyFields() throws {
        #expect(try parse(",\na,,b,\n\"\"\n") == [["", ""], ["a", "", "b", ""], [""]])
        #expect(try parse("x,") == [["x", ""]])
    }

    @Test func handlesQuotedFields() throws {
        let text = "id,name,note\n1,\"Jay St, MetroTech\",\"say \"\"hi\"\"\"\n2,\"multi\nline\r\nfield\",plain\n"
        #expect(try parse(text) == [
            ["id", "name", "note"],
            ["1", "Jay St, MetroTech", "say \"hi\""],
            ["2", "multi\nline\r\nfield", "plain"],
        ])
        #expect(try parse("\"\"\"\"") == [["\""]])
        #expect(try parse("a\"b,c") == [["a\"b", "c"]]) // stray quote in an unquoted field is literal
    }

    @Test func acceptsEveryLineEnding() throws {
        let expected = [["a", "b"], ["c", "d"], ["e", "f"]]
        #expect(try parse("a,b\r\nc,d\r\ne,f\r\n") == expected)
        #expect(try parse("a,b\rc,d\re,f") == expected)
        #expect(try parse("a,b\nc,d\r\ne,f\r") == expected)
        #expect(try parse("a,b\r\n\r\nc,d\n\ne,f") == expected)
    }

    @Test func skipsByteOrderMark() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = Array("stop_id,stop_name\n127N,Times Sq\n".utf8)
        for chunkSize in [1, 2, 3, 4, 1024] {
            #expect(try parse(bom + body, chunkSize: chunkSize) == [["stop_id", "stop_name"], ["127N", "Times Sq"]])
        }
        // Only a complete leading BOM is special; a partial one is data.
        var partial = CSVReader(bytes: [0xEF, 0xBB] + Array(",x".utf8), chunkSize: 1)
        #expect(try partial.next().map { Array($0[0].bytes) } == [0xEF, 0xBB])
        #expect(try parse(bom, chunkSize: 1) == [])
    }

    @Test(arguments: [1, 2, 3, 5, 7, 13, 64])
    func chunkBoundariesDoNotMatter(chunkSize: Int) throws {
        let text = "\u{FEFF}h1,\"h,2\"\r\n\"a\"\"b\",\"c\r\nd\"\r\n,,\r\n\"\"\r\nlast,row"
        #expect(try parse(text, chunkSize: chunkSize) == parse(text))
        #expect(try parse(text, chunkSize: chunkSize) == [["h1", "h,2"], ["a\"b", "c\r\nd"], ["", "", ""], [""], ["last", "row"]])
    }

    @Test func randomRecordsRoundTripAtAnyChunkSize() throws {
        var rng = SplitMix64(seed: 4180)
        let alphabet: [Character] = ["a", "Z", "0", " ", ",", "\"", "\n", "\r", "é", "🚲"]
        for _ in 0..<50 {
            let records: [[String]] = (0..<(1 + rng.nextInt(below: 8))).map { _ in
                (0..<(1 + rng.nextInt(below: 5))).map { _ in
                    String((0..<rng.nextInt(below: 6)).map { _ in alphabet[rng.nextInt(below: alphabet.count)] })
                }
            }
            // A record holding one empty field would be written as a blank line, which is skipped.
            let writable = records.map { $0 == [""] ? ["x"] : $0 }
            let text = writable.map { $0.map(Self.quoteIfNeeded).joined(separator: ",") }
                .joined(separator: rng.nextInt(below: 2) == 0 ? "\n" : "\r\n")
            #expect(try parse(text, chunkSize: 1 + rng.nextInt(below: 9)) == writable)
        }
    }

    private static func quoteIfNeeded(_ field: String) -> String {
        // Bytes, not Characters: Swift treats "\r\n" as one Character.
        guard field.utf8.contains(where: { [UInt8(ascii: ","), UInt8(ascii: "\""), 10, 13].contains($0) }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @Test func reportsMalformedQuoting() {
        #expect(throws: CSVError.unterminatedQuote(record: 2)) { try parse("a\n\"open,b\n") }
        #expect(throws: CSVError.unexpectedByteAfterQuote(record: 1)) { try parse("\"closed\"x,b\n") }
    }

    @Test func readsFromFileHandles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = (0..<5000).map { "\($0),\"stop \($0), NY\",\($0 * 7)" }
        try Data(("id,name,value\n" + rows.joined(separator: "\n")).utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var reader = CSVReader(FileHandleChunkSource(handle, chunkSize: 4096))
        let header = CSVHeader(try #require(try reader.next()))
        let name = try header.requireIndex(of: "name"), value = try header.requireIndex(of: "value")
        var count = 0, total = 0
        while let record = try reader.next() {
            #expect(record[name] == "stop \(count), NY")
            total += try #require(record[value].int())
            count += 1
        }
        #expect(count == 5000)
        #expect(total == 7 * 4999 * 5000 / 2)
        #expect(reader.recordCount == 5001)
    }
}

@Suite struct CSVFieldAndHeaderTests {
    private func record(_ text: String) throws -> CSVRecord {
        var reader = CSVReader(bytes: Array(text.utf8))
        return try #require(try reader.next())
    }

    @Test func headerMapsTrimmedNamesToIndices() throws {
        let header = CSVHeader(try record(" trip_id ,arrival_time,\tstop_id,arrival_time"))
        #expect(header.names == ["trip_id", "arrival_time", "stop_id", "arrival_time"])
        #expect(header.index(of: "trip_id") == 0)
        #expect(header.index(of: "arrival_time") == 1)
        #expect(header.index(of: "stop_id") == 2)
        #expect(header.index(of: "shape_id") == nil)
        #expect(throws: CSVError.missingColumn("shape_id")) { try header.requireIndex(of: "shape_id") }
    }

    @Test func fieldsParseWithoutStrings() throws {
        let row = try record("42,-17,+8,,x1,99999999999999999999,-9223372036854775808,é")
        #expect(row.count == 8)
        #expect(row[0].int() == 42)
        #expect(row[1].int() == -17)
        #expect(row[2].int() == 8)
        #expect(row[3].int() == nil && row[3].isEmpty)
        #expect(row[4].int() == nil)
        #expect(row[5].int() == nil)
        #expect(row[6].int() == Int.min)
        #expect(row[7] == "é" && !(row[7] == "e"))
        #expect(row[8].isEmpty && row[-1].isEmpty) // past the end reads as empty
        #expect(Array(row[0].bytes) == [0x34, 0x32])
    }

    @Test func serviceDatesParseFromFieldBytes() throws {
        let row = try record("20261101,2026-11-01")
        #expect(ServiceDate(yyyymmddBytes: row[0].bytes) == ServiceDate(year: 2026, month: 11, day: 1))
        #expect(ServiceDate(yyyymmddBytes: row[1].bytes) == nil)
    }
}
