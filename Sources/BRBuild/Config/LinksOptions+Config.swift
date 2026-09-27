import BRConfig
import BRCore
import BRStreetCore

extension LinksOptions {
    /// The links build parameters from a config's `transit.links` section, with the hop
    /// tunables' defaults (``HopOptions``) and every core for `threads`. The walk profile's stairs
    /// multiplier is `WalkProfile`'s (the engine's), not a config value.
    public init(config links: ConfigLinks) {
        self.init(
            walk: WalkProfile(speedMetersPerSecond: Double(links.walkSpeedHundredthsMph) / 100 * 0.44704,
                              stairsMultiplier: WalkProfile.standard.stairsMultiplier),
            maxFootpathWalkSeconds: UInt32(links.maxFootpathWalkSeconds),
            minTransferSeconds: UInt32(links.minTransferSeconds),
            stationLinkMaxWalkMeters: Double(links.stationLinkMaxWalkMeters),
            accessSeconds: Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, UInt32(links.stationAccessSeconds[$0])) }),
            maxSnapMeters: Dictionary(uniqueKeysWithValues: TransitSystem.allCases.map { ($0, Double(links.maxSnapMeters[$0])) }),
            streetAccessOnlyInsideServiceArea: Set(links.streetAccessOnlyInsideServiceArea.map(\.system)),
            fixedTransfers: links.fixedTransfers.map { FixedTransfer(from: $0.from, to: $0.to, seconds: UInt32($0.seconds)) }
        )
    }

    /// What `links` is built with: ``init(config:)-(ConfigLinks)`` over `transit.links`, plus the
    /// two hop inputs the config carries elsewhere. The one-seat rule's reference day skips
    /// `calendar.holidays` (``HopOptions/holidays``), and its change after the bike is
    /// `transit.afterBikeChange`, the engine's (``HopOptions/afterBikeMinSeconds``, and
    /// ``HopOptions/afterBikeRidePermille`` = 10 × `ridePercent`: both round the same
    /// ⌊ride × percent ÷ 100⌋).
    public init(config document: ConfigDocument) {
        self.init(config: document.transit.links)
        hops.holidays = Set(document.calendar.holidays.map(\.date))
        hops.afterBikeMinSeconds = document.transit.afterBikeChange.minSeconds
        hops.afterBikeRidePermille = document.transit.afterBikeChange.ridePercent * 10
    }
}
