import BRBuild
import BRConfig
import BRCore
import BRData
import BRStreetCore
import Foundation

extension LinksOptions {
    /// The plan-of-record links parameters as literals: `LinksOptions`' defaults until links was
    /// built from config (P2a moved them to `Data/config`). The tests build with these;
    /// `LinksConfigTests` checks the committed config against them.
    static let standard = LinksOptions(
        walk: WalkProfile(speedMetersPerSecond: 3.5 * 0.44704, stairsMultiplier: 2),
        maxFootpathWalkSeconds: 480,
        minTransferSeconds: 30,
        stationLinkMaxWalkMeters: 350,
        accessSeconds: [.subway: 120, .lirr: 240, .bus: 30, .ferry: 120, .path: 120],
        maxSnapMeters: [.subway: 150, .bus: 150, .lirr: 150, .ferry: 250, .path: 150],
        streetAccessOnlyInsideServiceArea: [.path],
        fixedTransfers: FixedTransfer.pathSubway
    )
}

extension FixedTransfer {
    /// The plan's PATH↔subway minimums: WTC → 1 (WTC Cortlandt) about 4 min and → E (World
    /// Trade Center) about 6 min via the Oculus; 14th and 23rd St → the F/M about 3 min each;
    /// 33rd St → 34 St-Herald Sq (B D F M and N Q R W) about 4 min.
    static let pathSubway: [FixedTransfer] = [
        FixedTransfer(from: "P:place_WTC", to: "S:138", seconds: 240),
        FixedTransfer(from: "P:place_WTC", to: "S:E01", seconds: 360),
        FixedTransfer(from: "P:place_14S", to: "S:D19", seconds: 180),
        FixedTransfer(from: "P:place_23S", to: "S:D18", seconds: 180),
        FixedTransfer(from: "P:place_33S", to: "S:D17", seconds: 240),
        FixedTransfer(from: "P:place_33S", to: "S:R17", seconds: 240),
    ]
}

/// The config `links` is built from: the committed `Data/` sources, written as `config.bin`.
enum RepositoryConfig {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Data")

    /// The document compiled from `Data/config` and `Data/fares`.
    static func document() throws -> ConfigDocument {
        try ConfigSources(root: root).load()
    }

    /// Writes `document` as `config.bin` into `directory` (as the config compiler would, minus
    /// the reference checks) and returns the file.
    @discardableResult
    static func write(_ document: ConfigDocument, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(MappedConfig.fileName)
        try ConfigArtifactWriter.artifact(json: try ConfigArtifactWriter.json(document), dataVersion: "fixture").write(to: url)
        return url
    }
}
