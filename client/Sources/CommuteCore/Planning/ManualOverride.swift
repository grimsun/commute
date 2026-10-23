import Foundation

/// A choice made by hand over an automatic one (the mode, the direction), held while the
/// situation it was made in lasts: when `context` changes, the automatic value takes over again.
public struct ManualOverride<Value: Equatable & Sendable, Context: Equatable & Sendable>: Sendable {
    private var choice: (value: Value, context: Context)?

    public init() {}

    /// Choosing the automatic value itself just clears the override.
    public mutating func set(_ value: Value, automatic: Value, context: Context) {
        choice = value == automatic ? nil : (value, context)
    }

    /// The chosen value while its context holds, else `automatic`.
    public mutating func resolve(automatic: Value, context: Context) -> Value {
        guard let choice, choice.context == context else {
            choice = nil
            return automatic
        }
        return choice.value
    }

    public mutating func clear() {
        choice = nil
    }
}
