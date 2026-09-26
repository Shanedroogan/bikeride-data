import BRBuild
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct ServiceAreaTests {
    @Test func picksJerseyCityAndHobokenByTheirBoundaryTags() throws {
        let fixture = try StreetsFixtures.data("nj-municipalities-fixture.geojsonseq")
        let regions = try ServiceArea.municipalities(fromGeoJSONSequence: fixture, simplifyToleranceMeters: 10)
        #expect(regions.map(\.code) == [3432250, 3436000])
        #expect(regions.map(\.code) == [StreetRegion.hobokenCode, StreetRegion.jerseyCityCode])
        #expect(regions.map(\.name) == ["Hoboken", "Jersey City"])
        #expect(regions.allSatisfy { !$0.isNYCBorough })
        let hoboken = regions[0], jerseyCity = regions[1]
        #expect(jerseyCity.area.polygons.count == 1 && jerseyCity.area.polygons[0].holes.count == 1)
        #expect(jerseyCity.area.contains(Coordinate(lat: 40.71, lon: -74.035)))
        #expect(!jerseyCity.area.contains(Coordinate(lat: 40.704, lon: -74.03))) // the hole
        #expect(hoboken.area.contains(Coordinate(lat: 40.72, lon: -74.03)))
        // Neither the admin_level=6 county (same wikidata tag) nor Bayonne is taken.
        for region in regions { #expect(!region.area.contains(Coordinate(lat: 40.69, lon: -74.03))) }

        #expect(ServiceArea.municipalitiesFilter == "r/wikidata=Q138578,Q26339")
        #expect(ServiceArea.jerseyCity.osmRelation == 170953 && ServiceArea.hoboken.osmRelation == 170708)
    }

    @Test func aMissingMunicipalityIsAnError() throws {
        let lines = try StreetsFixtures.data("nj-municipalities-fixture.geojsonseq").split(separator: UInt8(ascii: "\n"))
        let withoutJerseyCity = Data(lines.filter { !String(decoding: $0, as: UTF8.self).contains(#""name": "Jersey City""#) }
            .joined(separator: [UInt8(ascii: "\n")]))
        #expect(throws: ServiceArea.ServiceAreaError.municipalBoundaryNotFound("Jersey City")) {
            try ServiceArea.municipalities(fromGeoJSONSequence: withoutJerseyCity, simplifyToleranceMeters: 10)
        }
    }

    @Test func theClipHullContainsEveryRegionPlusItsBuffer() {
        let regions = [
            StreetRegion(code: StreetRegion.jerseyCityCode, name: "Box", area: MultiPolygon([Polygon(exterior: [
                Coordinate(lat: 40.66, lon: -74.12), Coordinate(lat: 40.66, lon: -74.02), Coordinate(lat: 40.77, lon: -74.04),
                Coordinate(lat: 40.66, lon: -74.12),
            ])])),
            StreetRegion(code: StreetRegion.hobokenCode, name: "Box", area: MultiPolygon([Polygon(exterior: [
                Coordinate(lat: 40.73, lon: -74.04), Coordinate(lat: 40.73, lon: -74.02), Coordinate(lat: 40.76, lon: -74.02),
                Coordinate(lat: 40.73, lon: -74.04),
            ])])),
        ]
        let ring = ServiceArea.bufferedHull(of: regions, bufferMeters: 1500)
        #expect(ring.first == ring.last)
        let hull = Polygon(exterior: ring)
        // Every region point, and points 1.4 km outward from the extremes, are inside.
        for region in regions { for point in region.area.polygons[0].exterior { #expect(hull.contains(point)) } }
        let north = LocalProjection(origin: Coordinate(lat: 40.77, lon: -74.04))
        #expect(hull.contains(north.unproject(PlanarPoint(x: 0, y: 1400))))
        #expect(!hull.contains(north.unproject(PlanarPoint(x: 0, y: 1600))))
        let west = LocalProjection(origin: Coordinate(lat: 40.66, lon: -74.12))
        #expect(hull.contains(west.unproject(PlanarPoint(x: -1400, y: 0))))
        #expect(!hull.contains(west.unproject(PlanarPoint(x: -1600, y: 0))))

        let feature = ServiceArea.geoJSONPolygonFeature(ring)
        let json = try? JSONSerialization.jsonObject(with: feature) as? [String: Any]
        #expect((json?["geometry"] as? [String: Any])?["type"] as? String == "Polygon")
    }

    @Test func regionRasterLabelsPointsByRegion() {
        func square(_ lat: Double, _ lon: Double, _ size: Double) -> MultiPolygon {
            MultiPolygon([Polygon(exterior: [
                Coordinate(lat: lat, lon: lon), Coordinate(lat: lat + size, lon: lon), Coordinate(lat: lat + size, lon: lon + size),
                Coordinate(lat: lat, lon: lon + size), Coordinate(lat: lat, lon: lon),
            ])])
        }
        let raster = RegionRaster(regions: [square(40.70, -74.00, 0.02), square(40.70, -74.05, 0.02), square(40.705, -74.045, 0.01)])
        func region(_ lat: Double, _ lon: Double) -> Int? {
            raster.region(latE7: Int32((lat * 1e7).rounded()), lonE7: Int32((lon * 1e7).rounded()))
        }
        #expect(region(40.71, -73.99) == 0)
        #expect(region(40.701, -74.049) == 1)
        #expect(region(40.71, -74.04) == 1) // overlap: the first region wins
        #expect(region(40.71, -74.02) == nil)
        #expect(region(41.0, -74.0) == nil)
    }
}
