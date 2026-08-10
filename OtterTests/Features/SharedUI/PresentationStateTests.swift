import Testing
@testable import Otter

@Suite("Presentation state primitives")
struct PresentationStateTests {
    @Test("Load state exposes only the active payload")
    func activePayload() {
        let loaded = LoadState<Int>.loaded(42)
        let failed = LoadState<Int>.failed(
            PresentationFailure(title: "Unavailable", message: "Try again.")
        )

        #expect(loaded.value == 42)
        #expect(loaded.failure == nil)
        #expect(failed.value == nil)
        #expect(failed.failure?.title == "Unavailable")
    }

    @Test("Mapping transforms loaded values and preserves other states")
    func mapsLoadState() {
        let loaded = LoadState<Int>.loaded(21).map { "\($0 * 2)" }
        let loading = LoadState<Int>.loading.map(String.init)
        let failure = PresentationFailure(title: "Unavailable", message: "Try again.")
        let failed = LoadState<Int>.failed(failure).map(String.init)

        #expect(loaded == .loaded("42"))
        #expect(loading == .loading)
        #expect(failed == .failed(failure))
    }

    @Test("Action state reports only active work")
    func actionWorkState() {
        #expect(ActionState.working.isWorking)
        #expect(!ActionState.idle.isWorking)
        #expect(!ActionState.succeeded("Done").isWorking)
    }
}
