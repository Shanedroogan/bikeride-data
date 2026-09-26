import BRCore
import Foundation
import Testing

@Suite struct IdentifierTests {
    @Test func transitSystemCodes() {
        #expect(TransitSystem.allCases.map(\.rawValue) == ["S", "B", "L", "F"])
    }

    @Test func systemScopedIDsRoundTripTheirParts() {
        let stop = StopID(system: .subway, gtfsID: "127N")
        #expect(stop.rawValue == "S:127N")
        #expect(stop.system == .subway)
        #expect(stop.gtfsID == "127N")

        let trip = TripID(system: .bus, gtfsID: "MQ_A5-Weekday-SDon-012345_Q32_701")
        #expect(trip.system == .bus)
        #expect(trip.gtfsID == "MQ_A5-Weekday-SDon-012345_Q32_701")
    }

    @Test func unqualifiedIDsHaveNoSystem() {
        let route: RouteID = "M15+"
        #expect(route.system == nil)
        #expect(route.gtfsID == "M15+")
        #expect(StopID(rawValue: "X:1").system == nil)
        #expect(StopID(rawValue: "X:1").gtfsID == "X:1")
    }

    @Test func codeAsBareStrings() throws {
        let stations: [StationID: StopID] = ["66db2fd0-0aca-11e7-82f6-3863bb44ef7c": "S:A27"]
        let json = try JSONEncoder().encode([StationID("a"), StationID("b")])
        #expect(String(decoding: json, as: UTF8.self) == #"["a","b"]"#)
        let roundTripped = try JSONDecoder().decode([StationID: StopID].self, from: JSONEncoder().encode(stations))
        #expect(roundTripped == stations)
    }

    @Test func orderByRawValue() {
        #expect([StopID("S:B"), StopID("S:A")].sorted() == [StopID("S:A"), StopID("S:B")])
    }
}

@Suite struct SplitMix64Tests {
    @Test func matchesReferenceOutput() {
        var rng = SplitMix64(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
        #expect(rng.next() == 0x6E78_9E6A_A1B9_65F4)
        #expect(rng.next() == 0x06C4_5D18_8009_454F)
    }

    @Test func derivedValuesStayInRange() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<10_000 {
            let unit = rng.nextUnitDouble()
            #expect(unit >= 0 && unit < 1)
            #expect((0..<7).contains(rng.nextInt(below: 7)))
        }
    }
}
