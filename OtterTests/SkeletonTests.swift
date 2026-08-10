import Foundation
import Testing
@testable import Otter

@Suite("Otter project skeleton")
struct SkeletonTests {
    @Test("App route identity is stable")
    func routeIdentity() {
        let id = UUID()
        #expect(AppRoute.viewer(assetID: id) == .viewer(assetID: id))
    }
}
