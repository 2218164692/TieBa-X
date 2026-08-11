import Foundation

struct NavigationSourceLifecycleState: Equatable {
    private(set) var isOpeningParentDestination = false

    mutating func beginParentNavigation() {
        isOpeningParentDestination = true
    }

    mutating func didAppear() {
        isOpeningParentDestination = false
    }

    func shouldTearDown(isPresentingLocalDestination: Bool) -> Bool {
        isPresentingLocalDestination == false && isOpeningParentDestination == false
    }
}
