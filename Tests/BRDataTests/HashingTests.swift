import BRCore
import BRData
import Foundation
import Testing

@Suite struct HashingTests {
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private func hashers() throws -> [(name: String, hasher: any Hasher256)] {
        var hashers: [(String, any Hasher256)] = []
        #if canImport(CryptoKit)
        hashers.append(("CryptoKit", CryptoKitHasher()))
        #endif
        #if os(macOS) || os(Linux)
        hashers.append(("process", try ProcessHasher(runner: ProcessToolRunner())))
        #endif
        return hashers
    }

    @Test func knownVectors() throws {
        for (name, hasher) in try hashers() {
            #expect(try hasher.sha256(of: Data("abc".utf8)).hex == abc, "\(name)")
            #expect(try hasher.sha256(of: Data()).hex == empty, "\(name)")
        }
    }

    @Test func fileHashesMatchInMemoryHashes() throws {
        let directory = try TemporaryDirectory()
        let data = sampleBytes(count: 2_500_000, seed: 9)
        let url = directory.file("name with spaces\\and backslash.bin")
        try data.write(to: url)
        let digests = try hashers().map { try $0.hasher.sha256(ofFileAt: url) }
        let reference = try #require(try hashers().first).hasher.sha256(of: data)
        #expect(digests.allSatisfy { $0 == reference })
    }

    @Test func digestHexRoundTrips() throws {
        let digest = try #require(Digest256(hex: abc.uppercased()))
        #expect(digest.hex == abc)
        #expect(digest.bytes.count == 32)
        #expect(Digest256(hex: String(abc.dropLast())) == nil)
        #expect(Digest256(hex: String(abc.dropLast()) + "g") == nil)
        #expect(Digest256(bytes: [1, 2]) == nil)
        let json = try JSONEncoder().encode([digest])
        #expect(String(decoding: json, as: UTF8.self) == "[\"\(abc)\"]")
        #expect(try JSONDecoder().decode([Digest256].self, from: json) == [digest])
    }
}
