import Foundation

extension FlowsReport {
    /// Where a flows build whose own gate failed writes its report: beside `reportURL`, as
    /// `<name>-failed.json` (`reports/flows-failed.json` under `all`).
    public static func failedReportURL(for reportURL: URL) -> URL {
        reportURL.deletingLastPathComponent().appendingPathComponent("\(reportURL.deletingPathExtension().lastPathComponent)-failed.json")
    }

    /// Writes this report the way `bikeride-data flows` does, so that `reportURL` always describes
    /// the flows.bin in place (the gate's `flows` check reads it to vouch for that file):
    /// - built: `reportURL`, for the new flows.bin; a failed report left by an earlier build is removed.
    /// - gate-failed: the failed report only (``failedReportURL(for:)``). `reportURL` keeps
    ///   describing the older flows.bin, which was kept, and stays the next build's baseline: a
    ///   failed report would pass on the same rows (its `baselineMonthRows` are the built report's
    ///   `baselineForNext`), so a failed build still never becomes the reference.
    /// - kept previous: nothing is written.
    /// Returns the file written, if any.
    @discardableResult
    public func record(at reportURL: URL) throws -> URL? {
        let failedURL = Self.failedReportURL(for: reportURL)
        switch outcome {
        case .built:
            _ = try SetArtifacts.writeJSON(self, to: reportURL, pretty: true)
            if FileManager.default.fileExists(atPath: failedURL.path) { try FileManager.default.removeItem(at: failedURL) }
            return reportURL
        case .gateFailed:
            _ = try SetArtifacts.writeJSON(self, to: failedURL, pretty: true)
            return failedURL
        case .keptPrevious:
            return nil
        }
    }
}
