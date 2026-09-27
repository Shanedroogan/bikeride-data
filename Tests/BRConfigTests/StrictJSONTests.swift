import BRBuild
import Foundation
import Testing

/// The strict JSON reader under ``ConfigSources/strictDecode(_:from:file:)``, on small documents.
@Suite struct StrictJSONTests {
    struct Probe: Codable, Equatable {
        var n: Int
        var s: String
        var list: [Int]?
        var flags: [String: Bool]?
    }

    func decode(_ text: String) throws -> Probe {
        try ConfigSources.strictDecode(Probe.self, from: Data(text.utf8), file: "probe.json")
    }

    func error(_ bytes: Data) -> ConfigSourceError? {
        do {
            _ = try ConfigSources.strictDecode(Probe.self, from: bytes, file: "probe.json")
            return nil
        } catch let error as ConfigSourceError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    func error(_ text: String) -> ConfigSourceError? { error(Data(text.utf8)) }

    /// The syntax message of an `undecodable` error, or `nil`.
    func syntax(_ text: String) -> String? {
        guard case .undecodable(_, let message)? = error(text), message.hasPrefix("not valid JSON at line ") else { return nil }
        return message
    }

    @Test func escapesReadLikeTheDecoderReadsThem() throws {
        // Escapes in the source and JSONEncoder's own (it writes `/` as `\/`) must compare equal,
        // or every such string would be a false changedValue.
        let probe = try decode(#"{"n": 1, "s": "café 😀 a\/b \"q\" \\ \t\n", "list": [], "flags": {"x/y": true}}"#)
        #expect(probe == Probe(n: 1, s: "café 😀 a/b \"q\" \\ \t\n", list: [], flags: ["x/y": true]))
        #expect(try decode(#"{"n": 1, "s": "é"}"#).s == "é") // raw UTF-8
        #expect(try decode("{\"n\":-0,\"s\":\"\"}").n == 0)
        #expect(try decode(#"{"n": 1, "s": "", "list": null}"#).list == nil) // null is absent
    }

    @Test func duplicateKeysAreFoundAfterUnescaping() {
        #expect(error(#"{"n": 1, "n": 1, "s": ""}"#) == .duplicateKey(file: "probe.json", path: "$.n", line: 1))
        #expect(error(#"{"n": 1, "n": 2, "s": ""}"#) == .duplicateKey(file: "probe.json", path: "$.n", line: 1))
        #expect(error("{\n  \"n\": 1,\n  \"s\": \"\",\n  \"flags\": {\"a\": true,\n    \"a\": false}\n}")
            == .duplicateKey(file: "probe.json", path: "$.flags.a", line: 5))
        // Equal keys in different objects are not duplicates.
        #expect(error(#"{"n": 1, "s": "", "flags": {"n": true, "s": false}}"#) == nil)
    }

    @Test func numberFormsStayApart() {
        #expect(error(#"{"n": 7.0, "s": ""}"#) == .changedValue(file: "probe.json", path: "$.n"))
        #expect(error(#"{"n": 7e0, "s": ""}"#) == .changedValue(file: "probe.json", path: "$.n"))
        #expect(error(#"{"n": 1, "s": "", "list": [1, 2.0]}"#) == .changedValue(file: "probe.json", path: "$.list[1]"))
        // Out of Int's range: a type error from the decoder.
        guard case .undecodable? = error(#"{"n": 99999999999999999999, "s": ""}"#) else {
            Issue.record("expected undecodable")
            return
        }
    }

    @Test func invalidJSONIsRejectedWithItsPosition() {
        #expect(syntax(#"{"n": 1, "s": "",}"#) == "not valid JSON at line 1, column 18: expected a key string")
        #expect(syntax(#"{"n": 01, "s": ""}"#) == "not valid JSON at line 1, column 8: a number has a leading zero")
        #expect(syntax("{\"n\": 1,\n \"s\": \"x}") == "not valid JSON at line 2, column 10: unterminated string")
        #expect(syntax(#"{"n": 1, "s": "\ud83d"}"#)?.hasSuffix("unpaired surrogate escape") == true)
        #expect(syntax(#"{"n": 1, "s": "\udc00"}"#)?.hasSuffix("unpaired surrogate escape") == true)
        #expect(syntax(#"{"n": 1, "s": "\x"}"#)?.hasSuffix("invalid escape") == true)
        #expect(syntax("{\"n\": 1, \"s\": \"a\tb\"}")?.hasSuffix("unescaped control character in a string") == true)
        #expect(syntax(#"{"n": 1, "s": ""} x"#)?.hasSuffix("unexpected text after the JSON value") == true)
        #expect(syntax(#"{"n": 1, "s": ""}{}"#)?.hasSuffix("unexpected text after the JSON value") == true)
        #expect(syntax(#"{"n": 1e400, "s": ""}"#)?.hasSuffix("number 1e400 is out of range") == true)
        #expect(syntax(#"{"n": tru, "s": ""}"#)?.hasSuffix("unexpected character") == true)
        #expect(syntax(#"{"n": 1, "s": ''}"#)?.hasSuffix("unexpected character") == true)
        #expect(syntax("") == "not valid JSON at line 1, column 1: unexpected end of input")
        #expect(syntax(String(repeating: "[", count: 65) + String(repeating: "]", count: 65))?
            .hasSuffix("nested deeper than 64 levels") == true)
        #expect(syntax("\u{FEFF}{\"n\": 1, \"s\": \"\"}")?.hasSuffix("starts with a byte-order mark") == true)

        // Invalid UTF-8 inside a string.
        var bytes = Data(#"{"n": 1, "s": ""#.utf8)
        bytes.append(contentsOf: [0xC3, 0x28])
        bytes.append(contentsOf: Data(#""}"#.utf8))
        guard case .undecodable(_, let message)? = error(bytes) else {
            Issue.record("expected undecodable")
            return
        }
        #expect(message.hasSuffix("a string is not valid UTF-8"))
    }
}
