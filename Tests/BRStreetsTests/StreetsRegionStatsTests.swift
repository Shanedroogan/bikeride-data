import BRBuild
import Foundation
import Testing

/// `stats.regions`: street length per service-area region before and after the component filter,
/// the validation gate's streets input.
@Suite struct StreetsRegionStatsTests {
    @Test func perRegionLengthsAddUpToTheCityWideShares() throws {
        let f = try FixtureStreets.build()
        let names = Set(try StreetsFixtures.regions().map(\.name))
        #expect(Set(f.stats.regions.keys) == names)

        let regions = Array(f.stats.regions.values) + [f.stats.outsideRegions]
        let kept = regions.map(\.keptMeters).reduce(0, +)
        let total = regions.map(\.totalMeters).reduce(0, +)
        let keptOverall = f.stats.keptComponentMeters.reduce(0, +)
        #expect(abs(kept - keptOverall) <= 1e-6 * keptOverall)
        // keptComponentsLengthShare = kept / (all length before the filter).
        #expect(abs(total * f.stats.keptComponentsLengthShare - keptOverall) <= 1e-6 * keptOverall)
        #expect(f.stats.droppedComponentMeters > 0)
        #expect(abs((total - kept) - f.stats.droppedComponentMeters) <= 1e-6 * total)

        for (name, region) in f.stats.regions {
            #expect(region.keptMeters <= region.totalMeters, "\(name)")
            #expect(region.keptShare == (region.totalMeters > 0 ? region.keptMeters / region.totalMeters : 1), "\(name)")
        }
        // The fixture's streets lie in its boroughs, not in the New Jersey fixture regions west of it.
        #expect(f.stats.regions.values.contains { $0.totalMeters > 0 })
        print(f.stats.regions.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.keptMeters)/\($0.value.totalMeters)" })
    }

    @Test func withoutRegionsEverythingIsOutside() throws {
        var options = StreetBuildOptions()
        options.keepLargestComponentPerRegion = false
        let f = try FixtureStreets.build(options: options)
        #expect(f.stats.regions.values.allSatisfy { $0.totalMeters == 0 })
        #expect(abs(f.stats.outsideRegions.keptMeters - f.stats.keptComponentMeters.reduce(0, +)) <= 1e-6 * f.stats.outsideRegions.keptMeters)
    }
}
