import BRTimetable
import Testing

@Suite struct SubwayTripKeyTests {
    @Test func parsesStaticIDWithDoubleDot() throws {
        let key = try #require(SubwayTripKey(staticTripID: "ASP26GEN-1038-Sunday-00_000600_1..S03R"))
        #expect(key.originHundredths == 600)
        #expect(key.route == "1")
        #expect(key.direction == UInt8(ascii: "S"))
        #expect(key.path == "03R")
        #expect(key.originSeconds == 360)
    }

    @Test func parsesStaticIDWithSingleDot() throws {
        let key = try #require(SubwayTripKey(staticTripID: "BFA26GEN-GS049-Weekday-00_086750_GS.S04R"))
        #expect(key.originHundredths == 86750)
        #expect(key.route == "GS")
        #expect(key.direction == UInt8(ascii: "S"))
        #expect(key.path == "04R")
        #expect(key.originSeconds == 52050)
    }

    @Test func parsesSupplementedIDs() throws {
        let key = try #require(SubwayTripKey(staticTripID: "L0S1-1-1094-S02_000650_1..S15R"))
        #expect(key.originHundredths == 650)
        #expect(key.route == "1")
        #expect(key.path == "15R")
    }

    @Test func parsesNegativeOriginsAndEmptyPaths() throws {
        let key = try #require(SubwayTripKey(staticTripID: "X_-003000_FS.N"))
        #expect(key.originHundredths == -3000)
        #expect(key.originSeconds == -1800)
        #expect(key.route == "FS")
        #expect(key.direction == UInt8(ascii: "N"))
        #expect(key.path == "")
    }

    @Test func usesTheLeftmostMatchingUnderscore() throws {
        let key = try #require(SubwayTripKey(staticTripID: "A_B_123456_A..N_000100_C..S"))
        #expect(key.originHundredths == 123456)
        #expect(key.route == "A")
        #expect(key.path == "_000100_C..S")
    }

    @Test func rejectsMalformedIDs() {
        #expect(SubwayTripKey(staticTripID: "GO202_26_2") == nil)
        #expect(SubwayTripKey(staticTripID: "X_00060_1..S03R") == nil)      // five digits
        #expect(SubwayTripKey(staticTripID: "X_000600_1S03R") == nil)       // no dot
        #expect(SubwayTripKey(staticTripID: "X_000600_1..E03R") == nil)     // bad direction
        #expect(SubwayTripKey(staticTripID: "X_000600_a..N") == nil)        // lowercase route
        #expect(SubwayTripKey(staticTripID: "X_000600_..N") == nil)         // empty route
    }

    @Test func describesKeysInTheRealtimeForm() throws {
        let key = try #require(SubwayTripKey(staticTripID: "ASP26GEN-1038-Sunday-00_000600_1..S03R"))
        #expect(key.description == "000600_1.S03R")
        #expect(SubwayTripKey(realtimeTripID: key.description) == key)
        let negative = try #require(SubwayTripKey(staticTripID: "X_-003000_FS.N"))
        #expect(negative.description == "-003000_FS.N")
        #expect(SubwayTripKey(realtimeTripID: negative.description) == negative)
    }

    @Test func parsesRealtimeIDsOnlyWhenAnchored() throws {
        let key = try #require(SubwayTripKey(realtimeTripID: "000600_1..S03R"))
        #expect(key == SubwayTripKey(staticTripID: "ASP26GEN-1038-Sunday-00_000600_1..S03R"))
        #expect(SubwayTripKey(realtimeTripID: "X_000600_1..S03R") == nil)
        #expect(SubwayTripKey(realtimeTripID: "-006000_6..N") != nil)
    }
}
