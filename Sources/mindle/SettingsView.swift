import SwiftUI

struct SettingsView: View {
    @AppStorage("mindle.fontScale") private var defaultFontScale: Double = 1.0

    var body: some View {
        Form {
            Section("Reading") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Default Font Size")
                        Spacer()
                        Text(FontScaleSteps.percentageString(for: defaultFontScale))
                            .monospacedDigit()
                    }

                    Slider(
                        value: Binding(
                            get: { defaultFontScale },
                            set: { defaultFontScale = FontScaleSteps.snapToNearest($0) }
                        ),
                        in: 0.75...1.60,
                        step: 0.05
                    ) {
                        Text("Font Size")
                    } minimumValueLabel: {
                        Text("A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text("A").font(.system(size: 16))
                    }

                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: 16 * defaultFontScale, design: .serif))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
    }
}
