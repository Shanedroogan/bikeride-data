import BRBuild
import Testing

/// Placeholder so the target exists; the gate, manifest and heartbeat tests land here in M1.
@Suite struct BRPublishPlaceholderTests {
    @Test func targetBuilds() {
        #expect(Bool(true))
    }
}
