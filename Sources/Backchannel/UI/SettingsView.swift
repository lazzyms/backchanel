import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Models", systemImage: "cpu") {
                ModelPickerView(models: model.models, mode: .settings) { chosen in
                    Task { await model.library.useModel(chosen) }
                }
            }
            Tab("Meetings", systemImage: "waveform") {
                Form {
                    Stepper("Ask whether to keep going every \(model.session.checkpointMinutes) minutes",
                            value: Bindable(model.session).checkpointMinutes, in: 10...120, step: 10)
                    Text("Transcription never stops on its own. The floating capsule asks at each checkpoint; ignoring it keeps recording.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Apple Intelligence", value: OnDeviceLM.isAvailable ? "Ready" : (OnDeviceLM.availability ?? "Unavailable"))
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 560, height: 420)
    }
}
