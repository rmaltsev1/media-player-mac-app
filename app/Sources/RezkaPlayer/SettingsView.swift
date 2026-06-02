import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @AppStorage("sidecarDir") private var sidecarDir: String = SidecarManager.defaultSidecarDir
    @AppStorage("pythonPath") private var pythonPath: String = ""

    @State private var originField: String = ""

    var body: some View {
        Form {
            Section("HDRezka mirror") {
                TextField("Domain", text: $originField, prompt: Text("https://hdrezka.ag"))
                    .textFieldStyle(.roundedBorder)
                Text("HDRezka rotates domains and may be geo-blocked. Paste a mirror that works for you (include https://).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Apply domain") {
                    let v = originField.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty { state.origin = normalized(v) }
                }
            }

            Section("Python helper") {
                LabeledContent("Status") { Text(statusText).foregroundStyle(.secondary) }
                TextField("Sidecar folder", text: $sidecarDir).textFieldStyle(.roundedBorder)
                TextField("Python path (optional)", text: $pythonPath,
                          prompt: Text("auto (.venv or system python3)"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Restart helper") { state.sidecar.restart() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { originField = state.origin }
    }

    private func normalized(_ s: String) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        return "https://" + s
    }

    private var statusText: String {
        switch state.sidecar.state {
        case .ready(let p): return "Ready on port \(p)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let m): return m
        }
    }
}
