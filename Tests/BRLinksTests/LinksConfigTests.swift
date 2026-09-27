import BRBuild
import BRConfig
import BRCore
import BRStreetCore
import Testing

/// links is built from the config artifact: the committed `Data/` config carries the values that
/// were `LinksOptions`' defaults (``LinksOptions/standard``), so the switch changes no payload
/// byte (`LinksCompilerTests` compares the built payload against the literals').
@Suite struct LinksConfigTests {
    let document: ConfigDocument

    init() throws {
        document = try RepositoryConfig.document()
    }

    /// Field for field; moved here from `ConfigSourcesTests` with the literals.
    @Test func optionsFromTheCommittedConfigEqualTheLiterals() {
        let fromConfig = LinksOptions(config: document), literal = LinksOptions.standard
        #expect(fromConfig.walk.speedMetersPerSecond == literal.walk.speedMetersPerSecond)
        #expect(fromConfig.walk.speedMetersPerSecond == WalkProfile.standard.speedMetersPerSecond)
        #expect(fromConfig.walk.stairsMultiplier == literal.walk.stairsMultiplier)
        #expect(fromConfig.maxFootpathWalkSeconds == literal.maxFootpathWalkSeconds)
        #expect(fromConfig.minTransferSeconds == literal.minTransferSeconds)
        #expect(fromConfig.stationLinkMaxWalkMeters == literal.stationLinkMaxWalkMeters)
        #expect(fromConfig.accessSeconds == literal.accessSeconds)
        #expect(fromConfig.maxSnapMeters == literal.maxSnapMeters)
        #expect(fromConfig.streetAccessOnlyInsideServiceArea == literal.streetAccessOnlyInsideServiceArea)
        // Order doesn't reach the links bytes (each pair keeps its minimum), so compare as sets.
        #expect(Set(fromConfig.fixedTransfers) == Set(literal.fixedTransfers))
        #expect(fromConfig.fixedTransfers.count == FixedTransfer.pathSubway.count)
        #expect(fromConfig.threads == literal.threads)
    }

    /// The hop tunables stay `HopOptions`' (config doesn't carry them); the change after the bike
    /// and the holidays come from the config.
    @Test func hopOptionsTakeTheConfigsAfterBikeChangeAndHolidays() {
        let hops = LinksOptions(config: document).hops, standard = HopOptions.standard
        #expect(hops.enabled && hops.parameters == standard.parameters && hops.oneSeatFilter == standard.oneSeatFilter)
        #expect(hops.middayStartSeconds == standard.middayStartSeconds && hops.middayEndSeconds == standard.middayEndSeconds)
        #expect(document.transit.afterBikeChange == ConfigAfterBikeChange(minSeconds: 60, ridePercent: 10))
        #expect(hops.afterBikeMinSeconds == standard.afterBikeMinSeconds && hops.afterBikeRidePermille == standard.afterBikeRidePermille)
        // Apart from the holidays, the config's hop options are the literal ones.
        var withoutHolidays = hops
        withoutHolidays.holidays = []
        #expect(withoutHolidays == standard)
        #expect(hops.holidays == Set(document.calendar.holidays.map(\.date)) && hops.holidays.count == document.calendar.holidays.count)
        #expect(hops.holidays.contains(ServiceDate(year: 2026, month: 11, day: 26)))

        var changed = document
        changed.transit.afterBikeChange = ConfigAfterBikeChange(minSeconds: 90, ridePercent: 15)
        changed.calendar.holidays = []
        let other = LinksOptions(config: changed).hops
        #expect(other.afterBikeMinSeconds == 90 && other.afterBikeRidePermille == 150 && other.holidays.isEmpty)
    }
}
