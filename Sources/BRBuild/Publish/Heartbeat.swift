import BRCore
import BRData
import Foundation

/// `data/heartbeat.json`, written last by every successful run (after the manifest). The relay's
/// `/v1/health/data` reads `checkedAt` (fails past 30 h) and `lastTimetableSuccessAt` (fails past
/// 16 h, the widest gap between the 13:00 and 03:15 timetable runs plus queueing).
public struct SetHeartbeat: Codable, Sendable, Equatable {
    public static let fileName = "heartbeat.json"

    /// When this run finished checking (ISO 8601, UTC).
    public var checkedAt: String
    /// When the timetables were last built, or found unchanged (M4). `nil` only when no run has
    /// ever built them, which the relay treats as a failure.
    public var lastTimetableSuccessAt: String?
    public var setId: String
    /// The job that wrote it: `all`, or the M4 job name (`timetables`, `streets`, `flows`).
    public var job: String
    /// `built`: this run wrote the manifest it names.
    public var result: String

    public init(checkedAt: String, lastTimetableSuccessAt: String?, setId: String, job: String, result: String = "built") {
        self.checkedAt = checkedAt
        self.lastTimetableSuccessAt = lastTimetableSuccessAt
        self.setId = setId
        self.job = job
        self.result = result
    }

    /// The heartbeat for a run that wrote `manifest` at `now`. When the run built (or confirmed)
    /// the timetables, `lastTimetableSuccessAt` is `now`; otherwise it carries over from the
    /// previous heartbeat.
    public static func after(_ manifest: SetManifest, now: Date, job: String, timetablesSucceeded: Bool,
                             previous: SetHeartbeat?) -> SetHeartbeat {
        let stamp = SetArtifacts.isoTimestamp(now)
        return SetHeartbeat(checkedAt: stamp, lastTimetableSuccessAt: timetablesSucceeded ? stamp : previous?.lastTimetableSuccessAt,
                            setId: manifest.setId, job: job)
    }

    /// Whether the run that wrote `manifest` counts as a timetable success. By default it does
    /// when at least one `tt-*` is in the set fresh (not carried forward): a job that carried all
    /// five (a flows-only job) cannot have built them, so it can never hide a dead timetables job
    /// by forgetting a flag. `unchanged` is the timetables job that found its sources unchanged
    /// and carried the five forward (a success); `notRun` a job that has `tt-*` files in its data
    /// directory without building them.
    public static func timetablesSucceeded(_ manifest: SetManifest, notRun: Bool, unchanged: Bool) -> Bool {
        if notRun { return false }
        if unchanged { return true }
        return TransitSystem.allCases.map { ArtifactKind.timetable(for: $0).name }.contains {
            manifest.artifacts[$0] != nil && !manifest.carriedForward.contains($0)
        }
    }

    /// Writes `<data>/heartbeat.json` for `manifest`, which this run just wrote: the job's name,
    /// and `lastTimetableSuccessAt` per ``timetablesSucceeded(_:notRun:unchanged:)``, carried over
    /// from `previousHeartbeat` (when it reads) otherwise. `bikeride-data all` (its last step) and
    /// `bikeride-data manifest` both write it here, so the tests drive the same code.
    @discardableResult
    public static func write(for manifest: SetManifest, data: URL, previousHeartbeat: URL?, now: Date, job: String,
                             notRun: Bool, unchanged: Bool) throws -> SetHeartbeat {
        let heartbeat = after(manifest, now: now, job: job,
                              timetablesSucceeded: timetablesSucceeded(manifest, notRun: notRun, unchanged: unchanged),
                              previous: previousHeartbeat.flatMap { try? load($0) })
        try heartbeat.write(to: data.appendingPathComponent(fileName))
        return heartbeat
    }

    public static func load(_ url: URL) throws -> SetHeartbeat {
        try JSONDecoder().decode(SetHeartbeat.self, from: Data(contentsOf: url))
    }

    @discardableResult
    public func write(to url: URL) throws -> Data {
        try SetArtifacts.writeJSON(self, to: url, pretty: false)
    }
}
