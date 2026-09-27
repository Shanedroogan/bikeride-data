import BRConfig
import BRCore
import BRStreetCore

extension LinksOptions {
    /// The links build parameters from a config's `transit.links` section. Everything else
    /// (`threads`, the walk profile's stairs multiplier) keeps its default. For the compiled
    /// `Data/` this equals `LinksOptions()` field for field (`ConfigSourcesTests`); `links` is
    /// built from it once `LinksCompiler` reads config.bin.
    public init(config links: ConfigLinks) {
        self.init()
        walk = WalkProfile(speedMetersPerSecond: Double(links.walkSpeedHundredthsMph) / 100 * 0.44704,
                           stairsMultiplier: walk.stairsMultiplier)
        maxFootpathWalkSeconds = UInt32(links.maxFootpathWalkSeconds)
        minTransferSeconds = UInt32(links.minTransferSeconds)
        stationLinkMaxWalkMeters = Double(links.stationLinkMaxWalkMeters)
        accessSeconds = Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, UInt32(links.stationAccessSeconds[$0])) })
        maxSnapMeters = Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, Double(links.maxSnapMeters[$0])) })
        streetAccessOnlyInsideServiceArea = Set(links.streetAccessOnlyInsideServiceArea.map(\.system))
        fixedTransfers = links.fixedTransfers.map { FixedTransfer(from: $0.from, to: $0.to, seconds: UInt32($0.seconds)) }
    }
}
