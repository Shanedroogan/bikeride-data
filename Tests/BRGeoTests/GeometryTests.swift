import BRGeo
import Testing

@Suite struct DistanceAndBearingTests {
    let unionSquare = Coordinate(lat: 40.7359, lon: -73.9911)
    let washingtonSquare = Coordinate(lat: 40.7308, lon: -73.9973)

    @Test func unionSquareToWashingtonSquare() {
        // Reference value computed independently with the same mean radius.
        #expect(abs(unionSquare.distance(to: washingtonSquare) - 771.04) < 1)
        #expect(abs(unionSquare.distance(to: washingtonSquare) - washingtonSquare.distance(to: unionSquare)) < 1e-9)
    }

    @Test func rosettaCodeReferenceDistance() {
        // BNA → LAX with R = 6372.8 km: 2887.2599506 km (Rosetta Code "Haversine formula").
        let bna = Coordinate(lat: 36.12, lon: -86.67), lax = Coordinate(lat: 33.94, lon: -118.40)
        #expect(abs(bna.distance(to: lax, radius: 6_372_800) - 2_887_259.95) < 0.1)
    }

    @Test func oneDegreeOfLatitude() {
        let a = Coordinate(lat: 40, lon: -74), b = Coordinate(lat: 41, lon: -74)
        #expect(abs(a.distance(to: b) - 111_195.08) < 0.01)
        #expect(a.distance(to: a) == 0)
    }

    @Test func bearings() {
        let origin = Coordinate(lat: 0, lon: 0)
        #expect(abs(origin.initialBearing(to: Coordinate(lat: 1, lon: 0)) - 0) < 1e-9)
        #expect(abs(origin.initialBearing(to: Coordinate(lat: 0, lon: 1)) - 90) < 1e-9)
        #expect(abs(origin.initialBearing(to: Coordinate(lat: -1, lon: 0)) - 180) < 1e-9)
        #expect(abs(origin.initialBearing(to: Coordinate(lat: 0, lon: -1)) - 270) < 1e-9)
        #expect(abs(unionSquare.initialBearing(to: washingtonSquare) - 222.653) < 0.01)
    }
}

@Suite struct LocalProjectionTests {
    let projection = LocalProjection(origin: Coordinate(lat: 40.7549, lon: -73.9840))

    @Test func roundTrips() {
        let c = Coordinate(lat: 40.6892, lon: -74.0445)
        let back = projection.unproject(projection.project(c))
        #expect(abs(back.lat - c.lat) < 1e-12 && abs(back.lon - c.lon) < 1e-12)
        #expect(projection.project(projection.origin) == PlanarPoint(x: 0, y: 0))
    }

    @Test func agreesWithHaversineAcrossTheCity() {
        let pairs = [
            (Coordinate(lat: 40.7359, lon: -73.9911), Coordinate(lat: 40.7308, lon: -73.9973)),
            (Coordinate(lat: 40.7527, lon: -73.9772), Coordinate(lat: 40.7505, lon: -73.9934)),
            (Coordinate(lat: 40.5795, lon: -73.9819), Coordinate(lat: 40.5760, lon: -73.9700)),
            (Coordinate(lat: 40.8820, lon: -73.9050), Coordinate(lat: 40.8850, lon: -73.9000)),
        ]
        for (a, b) in pairs {
            let truth = a.distance(to: b)
            #expect(abs(projection.distance(a, b) - truth) / truth < 0.005)
        }
    }

    @Test func projectsOntoSegments() {
        let a = PlanarPoint(x: 0, y: 0), b = PlanarPoint(x: 100, y: 0)
        let middle = PlanarPoint(x: 25, y: 10).projection(ontoSegmentFrom: a, to: b)
        #expect(middle == SegmentProjection(point: PlanarPoint(x: 25, y: 0), fraction: 0.25, distance: 10))
        let before = PlanarPoint(x: -30, y: 40).projection(ontoSegmentFrom: a, to: b)
        #expect(before.fraction == 0 && before.point == a && before.distance == 50)
        let after = PlanarPoint(x: 103, y: -4).projection(ontoSegmentFrom: a, to: b)
        #expect(after.fraction == 1 && after.point == b && after.distance == 5)
        let degenerate = PlanarPoint(x: 3, y: 4).projection(ontoSegmentFrom: a, to: a)
        #expect(degenerate.fraction == 0 && degenerate.distance == 5)
    }

    @Test func projectsCoordinatesOntoSegments() {
        let west = Coordinate(lat: 40.7500, lon: -73.9900), east = Coordinate(lat: 40.7500, lon: -73.9800)
        let result = projection.projection(of: Coordinate(lat: 40.7509, lon: -73.9850), ontoSegmentFrom: west, to: east)
        #expect(abs(result.fraction - 0.5) < 1e-9)
        #expect(abs(result.distance - 100.08) < 0.1)
    }
}

@Suite struct PolygonTests {
    // A 4 × 4 box with a 2 × 2 hole in the middle, in degrees for easy reasoning.
    let donut = Polygon(
        exterior: [Coordinate(lat: 0, lon: 0), Coordinate(lat: 0, lon: 4), Coordinate(lat: 4, lon: 4), Coordinate(lat: 4, lon: 0)],
        holes: [[Coordinate(lat: 1, lon: 1), Coordinate(lat: 1, lon: 3), Coordinate(lat: 3, lon: 3), Coordinate(lat: 3, lon: 1), Coordinate(lat: 1, lon: 1)]]
    )

    @Test func respectsHoles() {
        #expect(donut.contains(Coordinate(lat: 0.5, lon: 0.5)))
        #expect(donut.contains(Coordinate(lat: 3.5, lon: 2)))
        #expect(!donut.contains(Coordinate(lat: 2, lon: 2)))
        #expect(!donut.contains(Coordinate(lat: 5, lon: 2)))
        #expect(!donut.contains(Coordinate(lat: 2, lon: -0.1)))
    }

    @Test func handlesConcaveRings() {
        // A "U": the notch between the arms is outside.
        let u = Polygon(exterior: [
            Coordinate(lat: 0, lon: 0), Coordinate(lat: 0, lon: 3), Coordinate(lat: 3, lon: 3), Coordinate(lat: 3, lon: 2),
            Coordinate(lat: 1, lon: 2), Coordinate(lat: 1, lon: 1), Coordinate(lat: 3, lon: 1), Coordinate(lat: 3, lon: 0),
        ])
        #expect(u.contains(Coordinate(lat: 2, lon: 0.5)))
        #expect(u.contains(Coordinate(lat: 2, lon: 2.5)))
        #expect(!u.contains(Coordinate(lat: 2, lon: 1.5)))
        #expect(u.contains(Coordinate(lat: 0.5, lon: 1.5)))
    }

    @Test func multiPolygonContainsAnyMember() {
        let islands = MultiPolygon([
            donut,
            Polygon(exterior: [Coordinate(lat: 10, lon: 10), Coordinate(lat: 10, lon: 11), Coordinate(lat: 11, lon: 11)]),
        ])
        #expect(islands.contains(Coordinate(lat: 10.2, lon: 10.8)))
        #expect(islands.contains(Coordinate(lat: 0.5, lon: 0.5)))
        #expect(!islands.contains(Coordinate(lat: 2, lon: 2)))
        #expect(!islands.contains(Coordinate(lat: 10.8, lon: 10.2)))
    }

    @Test func degenerateRingsContainNothing() {
        #expect(!Polygon(exterior: []).contains(Coordinate(lat: 0, lon: 0)))
        #expect(!Polygon(exterior: [Coordinate(lat: 0, lon: 0), Coordinate(lat: 1, lon: 1)]).contains(Coordinate(lat: 0.5, lon: 0.5)))
    }
}

@Suite struct PolylineTests {
    let reference = [Coordinate(lat: 38.5, lon: -120.2), Coordinate(lat: 40.7, lon: -120.95), Coordinate(lat: 43.252, lon: -126.453)]

    @Test func encodesGoogleReference() {
        #expect(Polyline.encode(reference) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    @Test func decodesGoogleReference() throws {
        let decoded = try Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        #expect(decoded.count == reference.count)
        for (a, b) in zip(decoded, reference) {
            #expect(abs(a.lat - b.lat) < 1e-9 && abs(a.lon - b.lon) < 1e-9)
        }
    }

    @Test(arguments: [5, 6])
    func roundTripsAtPrecision(precision: Int) throws {
        let points = [
            Coordinate(lat: 40.712_776, lon: -74.005_974), Coordinate(lat: 40.712_777, lon: -74.005_973),
            Coordinate(lat: -33.868_820, lon: 151.209_296), Coordinate(lat: 0, lon: 0), Coordinate(lat: 89.999_999, lon: -179.999_999),
        ]
        let tolerance = precision == 5 ? 0.5e-5 : 0.5e-6
        let decoded = try Polyline.decode(Polyline.encode(points, precision: precision), precision: precision)
        #expect(decoded.count == points.count)
        for (a, b) in zip(decoded, points) {
            #expect(abs(a.lat - b.lat) <= tolerance + 1e-12 && abs(a.lon - b.lon) <= tolerance + 1e-12)
        }
    }

    @Test func precisionSixDiffersFromFive() throws {
        let encoded = Polyline.encode(reference, precision: 6)
        #expect(encoded != Polyline.encode(reference))
        let decoded = try Polyline.decode(encoded, precision: 6)
        #expect(abs(decoded[2].lon - -126.453) < 1e-9)
    }

    @Test func rejectsMalformedInput() throws {
        #expect(throws: Polyline.DecodingError.truncated) { try Polyline.decode("_p~iF~ps|") }
        #expect(throws: Polyline.DecodingError.missingLongitude) { try Polyline.decode("_p~iF") }
        #expect(throws: Polyline.DecodingError.invalidCharacter(offset: 2)) { try Polyline.decode("_p iF~ps|U") }
        #expect(throws: Polyline.DecodingError.valueTooLarge(offset: 12)) { try Polyline.decode(String(repeating: "~", count: 13)) }
        #expect(try Polyline.decode("").isEmpty)
    }
}
