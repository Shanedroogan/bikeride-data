// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BikeRideData",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "BRCore", targets: ["BRCore"]),
        .library(name: "BRGeo", targets: ["BRGeo"]),
        .library(name: "BRData", targets: ["BRData"]),
        .library(name: "BRStreetCore", targets: ["BRStreetCore"]),
        .library(name: "BRTimetable", targets: ["BRTimetable"]),
        .library(name: "BRBuild", targets: ["BRBuild"]),
        .executable(name: "bikeride-data", targets: ["bikeride-data"]),
    ],
    targets: [
        .target(name: "BRCore"),
        .target(name: "BRGeo"),
        .target(name: "BRData", dependencies: ["BRCore"]),
        .target(name: "BRStreetCore", dependencies: ["BRGeo", "BRData"]),
        .target(name: "BRTimetable", dependencies: ["BRCore", "BRGeo", "BRData"]),
        .target(name: "BRBuild", dependencies: ["BRCore", "BRGeo", "BRData", "BRStreetCore", "BRTimetable"]),
        .executableTarget(name: "bikeride-data", dependencies: ["BRCore", "BRGeo", "BRData", "BRStreetCore", "BRTimetable", "BRBuild"]),

        .testTarget(name: "BRCoreTests", dependencies: ["BRCore"]),
        .testTarget(name: "BRGeoTests", dependencies: ["BRGeo", "BRCore"]),
        .testTarget(name: "BRDataTests", dependencies: ["BRData", "BRCore"]),
        .testTarget(name: "BRStreetCoreTests", dependencies: ["BRStreetCore", "BRGeo", "BRCore"]),
        .testTarget(name: "BRBuildTests", dependencies: ["BRBuild", "BRCore"]),
        .testTarget(name: "BRTimetableTests", dependencies: ["BRTimetable", "BRBuild", "BRData", "BRGeo", "BRCore"]),
        .testTarget(name: "BRStreetsTests", dependencies: ["BRBuild", "BRStreetCore", "BRData", "BRGeo", "BRCore"]),
        .testTarget(name: "BRStationsTests", dependencies: ["BRBuild", "BRStreetCore", "BRData", "BRGeo", "BRCore"]),
        .testTarget(name: "BRLinksTests", dependencies: ["BRBuild", "BRStreetCore", "BRTimetable", "BRData", "BRGeo", "BRCore"]),
    ],
    swiftLanguageModes: [.v6]
)
