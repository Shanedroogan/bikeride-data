import BRBuild
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct ServiceAreaTests {
    @Test func picksHudsonCountyByItsFIPSCode() throws {
        let hudson = try ServiceArea.hudsonCounty(
            fromGeoJSONSequence: StreetsFixtures.data("hudson-county-fixture.geojsonseq"), simplifyToleranceMeters: 10
        )
        #expect(hudson.code == StreetRegion.hudsonCountyCode && hudson.code == 34017)
        #expect(hudson.name == "Hudson County")
        #expect(!hudson.isNYCBorough)
        #expect(hudson.area.polygons.count == 1 && hudson.area.polygons[0].holes.count == 1)
        #expect(hudson.area.contains(Coordinate(lat: 40.71, lon: -74.035)))
        #expect(!hudson.area.contains(Coordinate(lat: 40.704, lon: -74.03))) // the hole

        // Only the county's own polygon qualifies: the untagged decoy does not.
        let decoyOnly = try StreetsFixtures.data("hudson-county-fixture.geojsonseq").split(separator: UInt8(ascii: "\n"))[0]
        #expect(throws: ServiceArea.ServiceAreaError.hudsonCountyBoundaryNotFound) {
            try ServiceArea.hudsonCounty(fromGeoJSONSequence: Data(decoyOnly), simplifyToleranceMeters: 10)
        }
    }

    @Test func newarkPennAreaIsADiscAroundTheStation() {
        let area = ServiceArea.newarkPennArea()
        #expect(area.code == StreetRegion.newarkPennAreaCode)
        let ring = area.area.polygons[0].exterior
        #expect(ring.first == ring.last && ring.count == 65)
        for point in ring {
            #expect(abs(point.distance(to: ServiceArea.newarkPennCenter) - 1500) < 5)
        }
        #expect(area.area.contains(Coordinate(lat: 40.7394, lon: -74.1557))) // Harrison PATH
    }

    @Test func theClipHullContainsEveryRegionPlusItsBuffer() {
        let regions = [
            ServiceArea.newarkPennArea(),
            StreetRegion(code: 34017, name: "Box", area: MultiPolygon([Polygon(exterior: [
                Coordinate(lat: 40.64, lon: -74.10), Coordinate(lat: 40.82, lon: -74.00), Coordinate(lat: 40.80, lon: -73.98),
                Coordinate(lat: 40.64, lon: -74.10),
            ])])),
        ]
        let ring = ServiceArea.bufferedHull(of: regions, bufferMeters: 1500)
        #expect(ring.first == ring.last)
        let hull = Polygon(exterior: ring)
        // Every region point, and points 1.4 km outward from the extremes, are inside.
        for region in regions { for point in region.area.polygons[0].exterior { #expect(hull.contains(point)) } }
        let projection = LocalProjection(origin: Coordinate(lat: 40.82, lon: -74.00))
        #expect(hull.contains(projection.unproject(PlanarPoint(x: 0, y: 1400))))
        #expect(!hull.contains(projection.unproject(PlanarPoint(x: 0, y: 1600))))
        let west = LocalProjection(origin: ServiceArea.newarkPennCenter)
        #expect(hull.contains(west.unproject(PlanarPoint(x: -2900, y: 0))))
        #expect(!hull.contains(west.unproject(PlanarPoint(x: -3100, y: 0))))

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
