@MainActor
final class AssistantPresentationGate {
    private(set) var hidden = false

    func setHidden(_ value: Bool) { hidden = value }

    @discardableResult
    func present(_ action: () -> Void) -> Bool {
        guard !hidden else { return false }
        action()
        return true
    }
}
