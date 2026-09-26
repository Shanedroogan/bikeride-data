import BRCore
import BRData
import BRGeo
import BRStreetCore
import Foundation

/// Serializes ``CompiledStreets`` as the `streets` artifact (layout: `docs/formats.md`), read
/// back by ``BRStreetCore/MappedStreetGraph``.
public enum StreetsArtifactWriter {
    /// One directed edge, before CSR packing.
    public struct DirectedEdge: Sendable, Equatable {
        public var source: UInt32
        public var target: UInt32
        public var lengthDecimeters: UInt32
        public var flags: UInt16
        public var bikeClass: UInt8
        /// Segment index, with ``StreetsFormat/reversedSegmentBit`` for B→A.
        public var segmentCode: UInt32
    }

    /// Every stored directed edge, sorted by (source, target, segment code): the CSR order.
    public static func directedEdges(_ streets: CompiledStreets) -> [DirectedEdge] {
        var edges: [DirectedEdge] = []
        edges.reserveCapacity(streets.segmentCount * 2)
        for s in 0..<streets.segmentCount {
            let a = streets.segmentNodes[2 * s], b = streets.segmentNodes[2 * s + 1]
            let length = streets.segmentLengthDecimeters[s]
            if streets.forwardFlags[s] != 0 {
                edges.append(DirectedEdge(source: a, target: b, lengthDecimeters: length, flags: streets.forwardFlags[s],
                                          bikeClass: streets.forwardClasses[s], segmentCode: UInt32(s)))
            }
            if streets.backwardFlags[s] != 0 {
                edges.append(DirectedEdge(source: b, target: a, lengthDecimeters: length, flags: streets.backwardFlags[s],
                                          bikeClass: streets.backwardClasses[s],
                                          segmentCode: UInt32(s) | StreetsFormat.reversedSegmentBit))
            }
        }
        edges.sort { ($0.source, $0.target, $0.segmentCode) < ($1.source, $1.target, $1.segmentCode) }
        return edges
    }

    /// The same graph built in memory through ``BRStreetCore/GraphBuilder``, independently of the
    /// artifact bytes (node and edge numbering match the artifact's).
    public static func makeStreetGraph(_ streets: CompiledStreets) -> StreetGraph {
        var builder = GraphBuilder()
        for node in 0..<streets.nodeCount {
            builder.addNode(at: Coordinate(
                lat: StreetsFormat.degrees(streets.nodeCoordinates[2 * node]),
                lon: StreetsFormat.degrees(streets.nodeCoordinates[2 * node + 1])
            ))
        }
        for edge in directedEdges(streets) {
            let segment = Int(edge.segmentCode & ~StreetsFormat.reversedSegmentBit)
            builder.addEdge(
                from: edge.source, to: edge.target, lengthDecimeters: edge.lengthDecimeters,
                flags: EdgeFlags(rawValue: edge.flags), bikeClass: BikeClass(rawValue: edge.bikeClass) ?? .shared,
                nameID: streets.segmentNameIDs[segment]
            )
        }
        return builder.build()
    }

    /// The complete artifact file: header and payload.
    public static func artifact(_ streets: CompiledStreets, dataVersion: String, snapCellMeters: Double = 100) -> Data {
        let header = ArtifactHeader(
            kind: .streets,
            formatVersion: ArtifactKind.streets.currentFormatVersion,
            dataVersion: dataVersion,
            builderSwiftVersion: BuildInfo.swiftVersion
        )
        return header.assemble(payload: payload(streets, snapCellMeters: snapCellMeters))
    }

    public static func payload(_ streets: CompiledStreets, snapCellMeters: Double = 100) -> Data {
        let V = streets.nodeCount, S = streets.segmentCount
        let edges = directedEdges(streets)
        let E = edges.count

        var forwardOffsets = [UInt32](repeating: 0, count: V + 1)
        for edge in edges { forwardOffsets[Int(edge.source) + 1] += 1 }
        for node in 0..<V { forwardOffsets[node + 1] += forwardOffsets[node] }

        var reverseOffsets = [UInt32](repeating: 0, count: V + 1)
        for edge in edges { reverseOffsets[Int(edge.target) + 1] += 1 }
        for node in 0..<V { reverseOffsets[node + 1] += reverseOffsets[node] }
        var cursor = reverseOffsets
        var reverseSources = [UInt32](repeating: 0, count: E), reverseEdges = [UInt32](repeating: 0, count: E)
        for (index, edge) in edges.enumerated() {
            let slot = Int(cursor[Int(edge.target)])
            reverseSources[slot] = edge.source
            reverseEdges[slot] = UInt32(index)
            cursor[Int(edge.target)] += 1
        }

        var nameOffsets: [UInt32] = [0], nameBytes: [UInt8] = []
        for name in streets.names {
            nameBytes += Array(name.utf8)
            nameOffsets.append(UInt32(nameBytes.count))
        }

        let grid = snapGrid(streets, cellMeters: snapCellMeters)

        var w = BinaryWriter(reservingCapacity: 64 * E + (1 << 20))
        w.append(bytes: StreetsFormat.payloadMagic)
        w.append(StreetsFormat.draftRevision)
        w.append(UInt64(V))
        w.append(UInt64(E))
        w.append(UInt64(S))
        w.append(UInt64(streets.shapePoints.count / 2))
        w.append(UInt64(streets.names.count))
        w.append(array: streets.nodeCoordinates)
        w.append(array: forwardOffsets)
        w.append(array: edges.map(\.target))
        w.append(array: edges.map(\.lengthDecimeters))
        w.append(array: edges.map(\.flags))
        w.append(array: edges.map(\.bikeClass))
        w.append(array: edges.map(\.segmentCode))
        w.append(array: reverseOffsets)
        w.append(array: reverseSources)
        w.append(array: reverseEdges)
        w.append(array: streets.segmentNodes)
        w.append(array: streets.segmentNameIDs)
        w.append(array: streets.segmentBearings)
        w.append(array: streets.segmentShapeOffsets)
        w.append(array: streets.shapePoints)
        w.append(array: nameOffsets)
        w.append(array: nameBytes)
        w.append(array: streets.nameKinds.map(\.rawValue))
        w.append(grid.geometry.originLatE6)
        w.append(grid.geometry.originLonE6)
        w.append(grid.geometry.cellLatE6)
        w.append(grid.geometry.cellLonE6)
        w.append(UInt32(grid.geometry.columns))
        w.append(UInt32(grid.geometry.rows))
        w.append(array: grid.offsets)
        w.append(array: grid.segments)
        appendRegions(streets.regions, to: &w)
        return w.data
    }

    /// The snap grid: every cell a segment's stored polyline passes through lists it. Each
    /// polyline step is cut into pieces no longer than half a cell and each piece marks the cells
    /// its bounding box touches, a slight superset of the exact cover.
    static func snapGrid(_ streets: CompiledStreets, cellMeters: Double) -> (geometry: SnapGridGeometry, offsets: [UInt32], segments: [UInt32]) {
        var minLat = Int32.max, maxLat = Int32.min, minLon = Int32.max, maxLon = Int32.min
        func include(_ lat: Int32, _ lon: Int32) {
            minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            minLon = min(minLon, lon); maxLon = max(maxLon, lon)
        }
        for i in stride(from: 0, to: streets.nodeCoordinates.count, by: 2) { include(streets.nodeCoordinates[i], streets.nodeCoordinates[i + 1]) }
        for i in stride(from: 0, to: streets.shapePoints.count, by: 2) { include(streets.shapePoints[i], streets.shapePoints[i + 1]) }
        if minLat > maxLat { (minLat, maxLat, minLon, maxLon) = (0, 0, 0, 0) }

        let metersPerDegree = Earth.meanRadiusMeters * .pi / 180
        let midLat = StreetsFormat.degrees(Int32((Int64(minLat) + Int64(maxLat)) / 2))
        let cellLat = max(1, Int32((cellMeters / metersPerDegree * 1e6).rounded()))
        let cellLon = max(1, Int32((cellMeters / (metersPerDegree * cos(midLat * .pi / 180)) * 1e6).rounded()))
        let columns = Int((Int64(maxLon) - Int64(minLon)) / Int64(cellLon)) + 1
        let rows = Int((Int64(maxLat) - Int64(minLat)) / Int64(cellLat)) + 1
        let geometry = SnapGridGeometry(originLatE6: minLat, originLonE6: minLon, cellLatE6: cellLat, cellLonE6: cellLon,
                                        columns: columns, rows: rows)

        var keys: [UInt64] = []
        keys.reserveCapacity(streets.segmentCount * 3)
        for s in 0..<streets.segmentCount {
            var lats: [Int64] = [], lons: [Int64] = []
            let a = Int(streets.segmentNodes[2 * s]), b = Int(streets.segmentNodes[2 * s + 1])
            lats.append(Int64(streets.nodeCoordinates[2 * a])); lons.append(Int64(streets.nodeCoordinates[2 * a + 1]))
            for p in Int(streets.segmentShapeOffsets[s])..<Int(streets.segmentShapeOffsets[s + 1]) {
                lats.append(Int64(streets.shapePoints[2 * p])); lons.append(Int64(streets.shapePoints[2 * p + 1]))
            }
            lats.append(Int64(streets.nodeCoordinates[2 * b])); lons.append(Int64(streets.nodeCoordinates[2 * b + 1]))
            var lastCell = -1
            for i in 1..<lats.count {
                let dLat = lats[i] - lats[i - 1], dLon = lons[i] - lons[i - 1]
                let steps = max(1, Int((max(Double(abs(dLat)) / Double(cellLat), Double(abs(dLon)) / Double(cellLon)) * 2).rounded(.up)))
                for k in 0..<steps {
                    let lat0 = lats[i - 1] + dLat * Int64(k) / Int64(steps), lat1 = lats[i - 1] + dLat * Int64(k + 1) / Int64(steps)
                    let lon0 = lons[i - 1] + dLon * Int64(k) / Int64(steps), lon1 = lons[i - 1] + dLon * Int64(k + 1) / Int64(steps)
                    let c0 = geometry.cell(latE6: min(lat0, lat1), lonE6: min(lon0, lon1))
                    let c1 = geometry.cell(latE6: max(lat0, lat1), lonE6: max(lon0, lon1))
                    for y in max(0, c0.y)...min(rows - 1, c1.y) {
                        for x in max(0, c0.x)...min(columns - 1, c1.x) {
                            let cell = y * columns + x
                            if cell == lastCell { continue }
                            keys.append(UInt64(cell) << 32 | UInt64(s))
                            lastCell = cell
                        }
                    }
                }
            }
        }
        keys.sort()
        var offsets = [UInt32](repeating: 0, count: columns * rows + 1)
        var segments: [UInt32] = []
        segments.reserveCapacity(keys.count)
        var previous = UInt64.max
        for key in keys where key != previous {
            previous = key
            offsets[Int(key >> 32) + 1] += 1
            segments.append(UInt32(truncatingIfNeeded: key))
        }
        for cell in 0..<(columns * rows) { offsets[cell + 1] += offsets[cell] }
        return (geometry, offsets, segments)
    }

    static func appendRegions(_ regions: [StreetRegion], to w: inout BinaryWriter) {
        w.append(UInt32(regions.count))
        for region in regions {
            w.append(region.code)
            w.append(string: region.name)
        }
        var polygonOffsets: [UInt32] = [0], ringOffsets: [UInt32] = [0], pointOffsets: [UInt32] = [0], points: [Int32] = []
        for region in regions {
            for polygon in region.area.polygons {
                for ring in [polygon.exterior] + polygon.holes {
                    for c in ring {
                        points.append(StreetsFormat.microdegrees(c.lat))
                        points.append(StreetsFormat.microdegrees(c.lon))
                    }
                    pointOffsets.append(UInt32(points.count / 2))
                }
                ringOffsets.append(UInt32(pointOffsets.count - 1))
            }
            polygonOffsets.append(UInt32(ringOffsets.count - 1))
        }
        w.append(array: polygonOffsets)
        w.append(array: ringOffsets)
        w.append(array: pointOffsets)
        w.append(array: points)
    }
}
