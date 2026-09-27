import BRConfig
import BRCore
import BRStreetCore

extension LinksOptions {
    /// What `links` is built with: the config's `transit.links`, and the hop options it carries
    /// (``HopOptions/init(config:)``), with every core for `threads`. The walk profile's stairs
    /// multiplier is `WalkProfile`'s (the engine's), not a config value.
    public init(config document: ConfigDocument) {
        let links = document.transit.links
        self.init(
            walk: WalkProfile(speedMetersPerSecond: Double(links.walkSpeedHundredthsMph) / 100 * 0.44704,
                              stairsMultiplier: WalkProfile.standard.stairsMultiplier),
            maxFootpathWalkSeconds: UInt32(links.maxFootpathWalkSeconds),
            minTransferSeconds: UInt32(links.minTransferSeconds),
            stationLinkMaxWalkMeters: Double(links.stationLinkMaxWalkMeters),
            accessSeconds: Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, UInt32(links.stationAccessSeconds[$0])) }),
            maxSnapMeters: Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, Double(links.maxSnapMeters[$0])) }),
            streetAccessOnlyInsideServiceArea: Set(links.streetAccessOnlyInsideServiceArea.map(\.system)),
            fixedTransfers: links.fixedTransfers.map { FixedTransfer(from: $0.from, to: $0.to, seconds: UInt32($0.seconds)) },
            hops: HopOptions(config: document)
        )
    }
}

extension HopOptions {
    /// The hop options with the two inputs the config carries: the one-seat rule's reference day
    /// skips `calendar.holidays` (``holidays``), and its change after the bike is
    /// `transit.afterBikeChange`, the engine's (``afterBikeMinSeconds``, and
    /// ``afterBikeRidePermille`` = 10 × `ridePercent`: both round the same ⌊ride × percent ÷ 100⌋).
    /// The hop tunables are `HopOptions`' defaults.
    public init(config document: ConfigDocument) {
        self.init(afterBikeMinSeconds: document.transit.afterBikeChange.minSeconds,
                  afterBikeRidePermille: document.transit.afterBikeChange.ridePercent * 10,
                  holidays: Set(document.calendar.holidays.map(\.date)))
    }
}
