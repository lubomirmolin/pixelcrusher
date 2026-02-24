import Testing
@testable import PixelCrusherMacCore

struct DropAffordanceLayoutStateTests {
    @Test("Populated state hides add-more CTA")
    func populatedStateHidesTopAddMoreCTA() {
        let state = PixelCrusherDropAffordanceLayoutState(hasItems: true)

        #expect(state.showsTopAddMoreCTA == false)
    }

    @Test("Populated state shows bottom drag hint")
    func populatedStateShowsBottomDragHint() {
        let state = PixelCrusherDropAffordanceLayoutState(hasItems: true)

        #expect(state.showsBottomDragHint == true)
    }

    @Test("Drop target stays active for populated state")
    func populatedStateKeepsFullWindowDropTarget() {
        let state = PixelCrusherDropAffordanceLayoutState(hasItems: true)

        #expect(state.usesFullWindowDropTarget == true)
    }
}
