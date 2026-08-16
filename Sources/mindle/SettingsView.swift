import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("mindle.fontScale") private var defaultFontScale: Double = 1.0
    @State private var sshProfiles: [SSHProfile] = []
    @State private var sshProfilesError: String?
    @State private var sshProfilesURL: URL?

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

            Section("SSH Profiles") {
                if let error = sshProfilesError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sshProfiles) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.favorite ? "star.fill" : "server.rack")
                                .foregroundStyle(profile.favorite ? .yellow : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                Text("\(profile.hostname):\(profile.rootPath)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if profile.favorite {
                                Text("Favorite")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack {
                    Button("Open YAML") {
                        if let url = sshProfilesURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(sshProfilesURL == nil)

                    Button("Reload") {
                        loadSSHProfiles()
                    }

                    Spacer()
                    if let url = sshProfilesURL {
                        Text(url.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .onAppear {
            loadSSHProfiles()
        }
    }

    private func loadSSHProfiles() {
        do {
            sshProfilesURL = try SSHProfileConfiguration.ensureConfigExists()
            sshProfiles = try SSHProfileConfiguration.load()
            sshProfilesError = nil
        } catch {
            sshProfiles = []
            sshProfilesError = error.localizedDescription
        }
    }
}
