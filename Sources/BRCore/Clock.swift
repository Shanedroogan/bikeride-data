import Foundation

/// The source of "now". Injected into every component that reads the time, so tests and
/// replays are deterministic.
///
/// Within modules that import BRCore this shadows the standard library's `Clock`.
public protocol Clock: Sendable {
    var now: Date { get }
}

/// The device clock.
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }
}

/// A clock pinned to one instant.
public struct FixedClock: Clock {
    public let now: Date

    public init(_ now: Date) {
        self.now = now
    }

    /// Pins the clock to an ISO 8601 timestamp that carries its offset,
    /// e.g. `2026-11-01T01:30:00-04:00`. Returns `nil` if the string does not parse.
    public init?(iso8601: String) {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return nil }
        self.init(date)
    }
}
