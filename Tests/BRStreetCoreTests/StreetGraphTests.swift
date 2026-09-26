import BRGeo
import BRStreetCore
import Testing

@Suite struct StreetGraphTests {
    private func threeNodeBuilder() -> GraphBuilder {
        var builder = GraphBuilder()
        for i in 0..<3 { builder.addNode(at: Coordinate(lat: 40.7 + Double(i) * 0.001, lon: -74)) }
        return builder
    }

    @Test func buildsForwardCSRSortedBySourceAndStable() {
        var builder = threeNodeBuilder()
        builder.addEdge(from: 2, to: 0, lengthDecimeters: 5, flags: .walk, nameID: 20)
        builder.addEdge(from: 0, to: 1, lengthDecimeters: 1, flags: .walk, nameID: 1)
        builder.addEdge(from: 0, to: 2, lengthDecimeters: 2, flags: .walk, nameID: 2)
        builder.addEdge(from: 0, to: 1, lengthDecimeters: 3, flags: .walk, nameID: 3)
        let graph = builder.build()
        #expect(graph.nodeCount == 3 && graph.edgeCount == 4)
        #expect(graph.forwardOffsets == [0, 3, 3, 4])
        #expect(graph.edgeNameIDs == [1, 2, 3, 20])
        #expect(graph.edgeTargets == [1, 2, 1, 0])
        #expect((0..<4).map(graph.sourceNode(ofEdge:)) == [0, 0, 0, 2])
    }

    @Test func reverseIndexListsEveryEdgeOnceAtItsTarget() {
        let graph = Fixtures.randomGraph(seed: 3)
        var seen = Set<UInt32>()
        for node in 0..<UInt32(graph.nodeCount) {
            for slot in graph.incomingEdges(of: node) {
                let edge = Int(graph.reverseEdges[slot])
                #expect(graph.edgeTargets[edge] == node)
                #expect(graph.sourceNode(ofEdge: edge) == graph.reverseSources[slot])
                #expect(seen.insert(UInt32(edge)).inserted)
            }
        }
        #expect(seen.count == graph.edgeCount)
    }

    @Test func streetsExpandToDirectedEdges() {
        var builder = threeNodeBuilder()
        builder.addStreet(between: 0, and: 1, lengthDecimeters: 10, bike: .forwardOnly, bikeClass: .painted, attributes: [.bridge, .walk])
        builder.addStreet(between: 1, and: 2, lengthDecimeters: 10, walkable: false, bike: .backwardOnly)
        builder.addStreet(between: 0, and: 2, lengthDecimeters: 10, walkable: false, bike: .none)
        let graph = builder.build()
        #expect(graph.edgeCount == 3)
        #expect(graph.edgeFlags[graph.outgoingEdges(of: 0).lowerBound] == [.walk, .bikeForward, .bridge])
        #expect(graph.edgeFlags[graph.outgoingEdges(of: 1).lowerBound] == [.walk, .bridge])
        #expect(graph.outgoingEdges(of: 2).map { graph.edgeFlags[$0] } == [.bikeForward])
        #expect(graph.outgoingEdges(of: 2).map { graph.edgeTargets[$0] } == [1])
        #expect(graph.edgeBikeClasses.first == .painted)
    }

    @Test func validatesRawArrays() throws {
        let nodes = [Coordinate(lat: 0, lon: 0), Coordinate(lat: 0, lon: 1)]
        func make(offsets: [UInt32], targets: [UInt32], lengths: [UInt32]? = nil) throws(StreetGraph.ValidationError) -> StreetGraph {
            try StreetGraph(
                nodeCoordinates: nodes, forwardOffsets: offsets, edgeTargets: targets,
                edgeLengthDecimeters: lengths ?? targets.map { _ in 1 },
                edgeFlags: targets.map { _ in .walk }, edgeBikeClasses: targets.map { _ in .shared },
                edgeNameIDs: targets.map { _ in 0 }
            )
        }
        #expect(try make(offsets: [0, 1, 2], targets: [1, 0]).reverseOffsets == [0, 1, 2])
        #expect(throws: StreetGraph.ValidationError.offsetCount(expected: 3, actual: 2)) { try make(offsets: [0, 2], targets: [1, 0]) }
        #expect(throws: StreetGraph.ValidationError.offsetsDoNotCoverEdges) { try make(offsets: [0, 1, 1], targets: [1, 0]) }
        #expect(throws: StreetGraph.ValidationError.offsetsNotMonotonic(node: 1)) { try make(offsets: [0, 3, 2], targets: [1, 0]) }
        #expect(throws: StreetGraph.ValidationError.targetOutOfRange(edge: 1)) { try make(offsets: [0, 1, 2], targets: [1, 2]) }
        #expect(throws: StreetGraph.ValidationError.edgeArrayLengthMismatch) { try make(offsets: [0, 1, 2], targets: [1, 0], lengths: [1]) }
    }
}

@Suite struct CostProfileTests {
    @Test func walkCostsAtThreePointFiveMph() {
        let walk = WalkProfile.standard
        #expect(walk.costMs(lengthDecimeters: 1000, flags: .walk, bikeClass: .arterial) == 63_912)
        #expect(walk.costMs(lengthDecimeters: 1000, flags: [.walk, .stairs], bikeClass: .shared) == 127_825)
        #expect(walk.costMs(lengthDecimeters: 1000, flags: .bikeForward, bikeClass: .shared) == nil)
        #expect(walk.costMs(lengthDecimeters: 0, flags: .walk, bikeClass: .shared) == 0)
    }

    @Test func bikeCostsScaleWithInfrastructure() {
        let bike = BikeProfile.eBike
        let expected: [BikeClass: UInt32] = [.protected: 17_895, .painted: 20_132, .shared: 22_369, .arterial: 29_080]
        for (bikeClass, ms) in expected {
            #expect(bike.costMs(lengthDecimeters: 1000, flags: .bikeForward, bikeClass: bikeClass) == ms)
        }
        #expect(bike.costMs(lengthDecimeters: 1000, flags: .walk, bikeClass: .protected) == nil)
        #expect(BikeProfile.classic.costMs(lengthDecimeters: 1000, flags: .bikeForward, bikeClass: .shared) == 27_962)
    }

    @Test func costsSaturateBelowTheUnreachedSentinel() {
        let slow = WalkProfile(speedMetersPerSecond: 0.0001)
        #expect(slow.costMs(lengthDecimeters: .max, flags: .walk, bikeClass: .shared) == StreetCost.maxFinite)
    }
}
