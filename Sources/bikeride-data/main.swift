import BRCore
import BRData
import Foundation

let usage = """
    USAGE: bikeride-data <command>

    COMMANDS:
      version     Print the tool, Swift and artifact format versions
      timetables  Build the tt-* timetables from GTFS (see: timetables --help)
      streets     Build the streets artifact from OSM (see: streets --help)
      streets-route  Route between two coordinates on build/data/streets.bin
      stations    Build the Citi Bike stations artifact and bike matrix (see: stations --help)
      links       Build footpaths, access points and station links (see: links --help)
      links-show  Print one stop's access points, footpaths and station links
      all         Build and publish a set: streets → timetables → stations → config → links → flows
                  → gate → manifest → heartbeat (see: all --help)
      config      Build the config artifact from Data/config and Data/fares (see: config --help)
      flows       Build the Citi Bike flows artifact from trip data (see: flows --help)
      gate        Run the validation gate over a built set (see: gate --help)
      manifest    Write the set manifest and heartbeat (see: manifest --help)
      help        Show this help
    """

func versionReport() -> String {
    let width = ArtifactKind.allCases.map(\.name.count).max() ?? 0
    let formats = ArtifactKind.allCases.map { kind in
        let version = kind.currentFormatVersion == 0 ? "0 (draft, not yet frozen)" : "\(kind.currentFormatVersion)"
        return "  \(kind.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(version)"
    }
    return ([
        "bikeride-data \(BuildInfo.toolVersion) (Swift \(BuildInfo.swiftVersion))",
        "artifact header layout \(ArtifactHeader.layoutVersion)",
        "artifact formats:",
    ] + formats).joined(separator: "\n")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("bikeride-data: \(message)\n\n\(usage)\n".utf8))
    exit(64) // EX_USAGE
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("missing command") }
if command == "timetables" { exit(runTimetablesCommand(Array(arguments.dropFirst()))) }
if command == "streets" { exit(runStreetsCommand(Array(arguments.dropFirst()))) }
if command == "streets-route" { exit(runStreetsRouteCommand(Array(arguments.dropFirst()))) }
if command == "stations" { exit(runStationsCommand(Array(arguments.dropFirst()))) }
if command == "links" { exit(runLinksCommand(Array(arguments.dropFirst()))) }
if command == "links-show" { exit(runLinksShowCommand(Array(arguments.dropFirst()))) }
if command == "all" { exit(runAllCommand(Array(arguments.dropFirst()))) }
if command == "config" { exit(runConfigCommand(Array(arguments.dropFirst()))) }
if command == "flows" { exit(runFlowsCommand(Array(arguments.dropFirst()))) }
if command == "gate" { exit(runGateCommand(Array(arguments.dropFirst()))) }
if command == "manifest" { exit(runManifestCommand(Array(arguments.dropFirst()))) }
guard arguments.count == 1 else { fail("'\(command)' takes no arguments") }

switch command {
case "version", "--version":
    print(versionReport())
case "help", "-h", "--help":
    print(usage)
default:
    fail("unknown command '\(command)'")
}
