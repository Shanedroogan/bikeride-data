import BRBuild
import BRCore
import BRGeo
import BRStreetCore
import Foundation
import Testing

@Suite struct GBFSStationsTests {
    @Test func findsTheEnglishStationInformationFeed() throws {
        let url = try GBFSStations.stationInformationURL(discovery: Data(GBFSFixture.discovery().utf8))
        #expect(url == "https://example.test/gbfs/en/station_information.json")
        #expect(try GBFSStations.stationInformationURL(discovery: Data(GBFSFixture.discovery().utf8), language: "fr")
            == "https://example.test/gbfs/fr/station_information.json")
        #expect(throws: GBFSStations.ParseError.noFeed(name: "station_information", language: "de")) {
            try GBFSStations.stationInformationURL(discovery: Data(GBFSFixture.discovery().utf8), language: "de")
        }
        #expect(throws: GBFSStations.ParseError.self) { try GBFSStations.stationInformationURL(discovery: Data("[]".utf8)) }
    }

    @Test func decodesStationsTolerantly() throws {
        let json = """
            {"last_updated":1790309897.5,"ttl":60,"data":{"stations":[
              {"station_id":"a1","name":"First","short_name":"5520.02","lat":40.7,"lon":-74.0,"region_id":"71","capacity":12,"is_charging":false},
              {"station_id":42,"name":"Numeric ids","short_name":6072,"lat":40.71,"lon":-74.01,"region_id":185,"capacity":7,"is_charging_station":1},
              {"station_id":"no-region","name":"No region","lat":40.72,"lon":-74.02,"capacity":3},
              {"station_id":"no-capacity","name":"No capacity","lat":40.72,"lon":-74.02},
              {"station_id":"bad","name":"Missing lat","lon":-74.0,"capacity":3},
              {"name":"Missing id","lat":40.7,"lon":-74.0},
              {"station_id":"far","name":"Bad lat","lat":123.0,"lon":-74.0}
            ]}}
            """
        let feed = try GBFSStations.parseStationInformation(Data(json.utf8))
        #expect(feed.lastUpdated == 1_790_309_897)
        #expect(feed.dropped == 3)
        #expect(feed.stations.map(\.stationID) == ["a1", "42", "no-region", "no-capacity"])
        #expect(feed.stations[0] == GBFSStation(stationID: "a1", name: "First", shortName: "5520.02", lat: 40.7, lon: -74.0,
                                                regionID: "71", capacity: 12, isCharging: false))
        #expect(feed.stations[1].shortName == "6072" && feed.stations[1].regionID == "185" && feed.stations[1].isCharging)
        #expect(feed.stations[2].regionID == nil && feed.stations[2].shortName == "")
        #expect(feed.stations[3].capacity == nil)
        #expect(throws: GBFSStations.ParseError.self) { try GBFSStations.parseStationInformation(Data("{\"data\":{}}".utf8)) }
    }
}

@Suite struct StationSelectionTests {
    let area = SyntheticCity.region(columns: 4, rows: 4).area

    @Test func keepsServiceAreaRegionsAndStationsInsideTheAreaWithDocks() {
        let inside = SyntheticCity.coordinate(1, 1), outside = SyntheticCity.coordinate(40, 40)
        let feed = [
            GBFSStation(stationID: "r71", name: "A", lat: inside.lat, lon: inside.lon, regionID: "71", capacity: 10),
            GBFSStation(stationID: "r185", name: "B", lat: outside.lat, lon: outside.lon, regionID: "185", capacity: 10),
            GBFSStation(stationID: "r158", name: "C", lat: inside.lat, lon: inside.lon, regionID: "158", capacity: 1),
            GBFSStation(stationID: "jc", name: "Jersey City", lat: outside.lat, lon: outside.lon, regionID: "70", capacity: 10),
            GBFSStation(stationID: "hob", name: "Hoboken", lat: outside.lat, lon: outside.lon, regionID: "311", capacity: 10),
            GBFSStation(stationID: "test189", name: "Test", lat: inside.lat, lon: inside.lon, regionID: "189", capacity: 10),
            GBFSStation(stationID: "test190", name: "Test 2", lat: inside.lat, lon: inside.lon, regionID: "190", capacity: 10),
            GBFSStation(stationID: "hobZero", name: "Hoboken, no docks", lat: inside.lat, lon: inside.lon, regionID: "311", capacity: 0),
            GBFSStation(stationID: "inside", name: "No region, inside", lat: inside.lat, lon: inside.lon, capacity: 5, isCharging: true),
            GBFSStation(stationID: "hoboken", name: "No region, outside", lat: outside.lat, lon: outside.lon, capacity: 5),
            GBFSStation(stationID: "empty", name: "No docks", lat: inside.lat, lon: inside.lon, regionID: "71", capacity: 0),
            GBFSStation(stationID: "unknown", name: "No capacity", lat: inside.lat, lon: inside.lon, regionID: "71"),
            GBFSStation(stationID: "r71", name: "Repeat", lat: inside.lat, lon: inside.lon, regionID: "71", capacity: 9),
            GBFSStation(stationID: "blank", name: "Empty region", lat: inside.lat, lon: inside.lon, regionID: "", capacity: 4),
        ]
        let (kept, stats) = StationsBuilder.select(feed, area: area)
        // A published region decides on its own; the polygon only judges stations without one.
        #expect(Set(kept.map(\.id)) == ["r71", "r185", "r158", "jc", "hob", "inside", "blank"])
        #expect(stats.feedStations == 14 && stats.accepted == 7 && stats.acceptedByArea == 2)
        #expect(stats.rejectedRegion == 2 && stats.rejectedRegionIDs == ["189": 1, "190": 1])
        #expect(stats.rejectedNoRegionOutsideArea == 1 && stats.rejectedCapacity == 3 && stats.duplicateIDs == 1)
        let first = kept.first { $0.id == "r71" }!
        #expect(first.name == "A" && first.capacity == 10 && first.regionID == "71" && first.flags.isEmpty)
        let byArea = kept.first { $0.id == "inside" }!
        #expect(byArea.flags == [.acceptedByArea, .charging] && byArea.regionID == nil)
        #expect(kept.first { $0.id == "blank" }!.regionID == nil)
    }

    @Test func ordersStationsAlongTheHilbertCurveThenByID() {
        var rng = SplitMix64(seed: 7)
        let feed = (0..<200).map { i -> GBFSStation in
            let c = SyntheticCity.coordinate(Double(rng.next() % 40), Double(rng.next() % 40))
            return GBFSStation(stationID: "s\(i)", name: "S\(i)", lat: c.lat, lon: c.lon, regionID: "71", capacity: 5)
        }
        let (kept, _) = StationsBuilder.select(feed, area: SyntheticCity.region(columns: 40, rows: 40).area)
        #expect(kept.count == 200)
        let keys = kept.map { StationsBuilder.orderKey(latE6: $0.latE6, lonE6: $0.lonE6) }
        for i in 1..<kept.count {
            #expect(keys[i - 1] < keys[i] || (keys[i - 1] == keys[i] && kept[i - 1].id.utf8.lexicographicallyPrecedes(kept[i].id.utf8)))
        }
        // The order does not depend on feed order.
        let (shuffled, _) = StationsBuilder.select(feed.reversed(), area: SyntheticCity.region(columns: 40, rows: 40).area)
        #expect(shuffled.map(\.id) == kept.map(\.id))
    }
}
