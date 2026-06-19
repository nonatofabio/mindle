/// Single source of truth for valid font-scale values.
/// All font-size UI (toolbar, menu, Settings stepper) indexes into this table.
/// Using a fixed table eliminates floating-point drift that accumulates
/// when repeatedly adding/subtracting 0.05.
enum FontScaleSteps {
    /// The 18 discrete font-scale multipliers, 0.75 through 1.60 in steps of 0.05.
    static let steps: [Double] = stride(from: 0.75, through: 1.60, by: 0.05)
        .map { ($0 * 100).rounded() / 100 }

    /// Snap an arbitrary Double to the nearest table entry.
    static func snapToNearest(_ value: Double) -> Double {
        steps.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }

    /// Index of the nearest step (for stepper arithmetic).
    static func index(of value: Double) -> Int {
        let snapped = snapToNearest(value)
        return steps.firstIndex(of: snapped) ?? steps.firstIndex(of: 1.0)!
    }

    /// Next step up, clamped at max.
    static func next(after value: Double) -> Double {
        let i = index(of: value)
        return steps[min(i + 1, steps.count - 1)]
    }

    /// Next step down, clamped at min.
    static func previous(before value: Double) -> Double {
        let i = index(of: value)
        return steps[max(i - 1, 0)]
    }

    /// Format a step value as a percentage string for display.
    static func percentageString(for value: Double) -> String {
        "\(Int((snapToNearest(value) * 100).rounded()))%"
    }
}
