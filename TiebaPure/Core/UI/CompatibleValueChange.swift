import SwiftUI

struct CompatibleValueChange<Value> {
    let oldValue: Value
    let newValue: Value
}

struct CompatibleValueChangeTracker<Value: Equatable> {
    private(set) var previousValue: Value
    private(set) var hasAppeared = false

    init(initialValue: Value) {
        previousValue = initialValue
    }

    mutating func appear(
        with currentValue: Value,
        sendsInitialChange: Bool
    ) -> CompatibleValueChange<Value>? {
        previousValue = currentValue
        guard hasAppeared == false else { return nil }
        hasAppeared = true
        guard sendsInitialChange else { return nil }
        return CompatibleValueChange(oldValue: currentValue, newValue: currentValue)
    }

    mutating func update(to newValue: Value) -> CompatibleValueChange<Value>? {
        let oldValue = previousValue
        previousValue = newValue
        guard oldValue != newValue else { return nil }
        return CompatibleValueChange(oldValue: oldValue, newValue: newValue)
    }
}

extension View {
    @ViewBuilder
    func compatibleOnChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        perform action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(LegacyValueChangeModifier(
                value: value,
                sendsInitialChange: initial,
                action: action
            ))
        }
    }
}

private struct LegacyValueChangeModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let sendsInitialChange: Bool
    let action: (_ oldValue: Value, _ newValue: Value) -> Void

    @State private var tracker: CompatibleValueChangeTracker<Value>

    init(
        value: Value,
        sendsInitialChange: Bool,
        action: @escaping (_ oldValue: Value, _ newValue: Value) -> Void
    ) {
        self.value = value
        self.sendsInitialChange = sendsInitialChange
        self.action = action
        _tracker = State(initialValue: CompatibleValueChangeTracker(initialValue: value))
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard let change = tracker.appear(
                    with: value,
                    sendsInitialChange: sendsInitialChange
                ) else { return }
                action(change.oldValue, change.newValue)
            }
            .onChange(of: value) { newValue in
                guard let change = tracker.update(to: newValue) else { return }
                action(change.oldValue, change.newValue)
            }
    }
}
