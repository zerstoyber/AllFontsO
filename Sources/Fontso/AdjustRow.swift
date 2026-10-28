import SwiftUI

/// One row of Adjust: label, optional extra control, slider, number field, and reset. Shared by Preview and Mix.
struct AdjustRow<Extra: View>: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var fraction: Int
    var reset: () -> Void
    private let extra: Extra

    init(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        fraction: Int,
        reset: @escaping () -> Void,
        @ViewBuilder extra: () -> Extra
    ) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.fraction = fraction
        self.reset = reset
        self.extra = extra()
    }

    var body: some View {
        let label = Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        // A plain slider without tick marks; the step still snaps the value.
        let snapped = Binding<Double>(
            get: { value },
            set: { value = SpecimenView.snap($0, step: step, range: range) }
        )
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                label.frame(width: 72, alignment: .leading)
                extra
                Slider(value: snapped, in: range)
                    .controlSize(.small)
                    .frame(minWidth: 48)
                field
                resetControl
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    label
                    extra
                    Spacer(minLength: 4)
                    field
                    resetControl
                }
                Slider(value: snapped, in: range)
                    .controlSize(.small)
            }
        }
    }

    private var field: some View {
        TextField(
            "",
            value: Binding(
                get: { value },
                set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
            ),
            format: .number.precision(.fractionLength(0...fraction))
        )
        .textFieldStyle(.roundedBorder)
        .font(.caption.monospacedDigit())
        .multilineTextAlignment(.trailing)
        .frame(width: 58)
        .controlSize(.small)
    }

    private var resetControl: some View {
        Button(action: reset) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .help("Reset \(title)")
    }
}

extension AdjustRow where Extra == EmptyView {
    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, fraction: Int, reset: @escaping () -> Void) {
        self.init(title: title, value: value, range: range, step: step, fraction: fraction, reset: reset) { EmptyView() }
    }
}
