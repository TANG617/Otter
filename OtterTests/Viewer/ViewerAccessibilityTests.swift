import Testing
import UIKit
@testable import Otter

@Suite("Viewer accessibility")
struct ViewerAccessibilityTests {
    @Test("Identifiers are stable and asset scoped")
    func identifiers() {
        let items = viewerTestItems(count: 2)
        #expect(ViewerAccessibilityID.screen == "viewer.screen")
        #expect(ViewerAccessibilityID.variantPicker == "viewer.variant")
        #expect(ViewerAccessibilityID.rate == "viewer.rate")
        #expect(ViewerAccessibilityID.media(assetID: items[0].id) != ViewerAccessibilityID.media(assetID: items[1].id))
        #expect(
            ViewerAccessibilityID.pageLabel(item: items[0], rating: .five, index: 0, count: 2)
                == "Photo, 1 of 2, 5 Stars"
        )
    }

    @Test("Rating labels cover every selectable state")
    func ratingLabels() {
        #expect(ViewerRatingLabel.text(for: nil) == "Unrated")
        #expect(ViewerRatingLabel.text(for: .rejected) == "Reject")
        #expect(ViewerRatingLabel.text(for: .one) == "1 Star")
        #expect(ViewerRatingLabel.text(for: .five) == "5 Stars")
        #expect(ViewerRatingChoice.stars.map(\.accessibilityIdentifier) == [
            "viewer.rating.1",
            "viewer.rating.2",
            "viewer.rating.3",
            "viewer.rating.4",
            "viewer.rating.5"
        ])
    }

    @Test("Rating menu exposes only Unrated and one through five stars")
    func ratingMenuChoices() {
        #expect(ViewerRatingChoice.stars.map(\.title) == [
            "1 Star",
            "2 Stars",
            "3 Stars",
            "4 Stars",
            "5 Stars"
        ])
        #expect(!ViewerRatingChoice.stars.contains { $0.value == .rejected })
    }

    @MainActor
    @Test("Zoom surface exposes image traits and VoiceOver actions")
    func zoomSurfaceActions() {
        let view = ZoomingImageScrollView()
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityTraits.contains(.image))
        #expect(view.accessibilityCustomActions?.map(\.name) == ["Zoom In", "Fit Photo"])
        #expect(view.accessibilityValue == "Fit")
    }
}
