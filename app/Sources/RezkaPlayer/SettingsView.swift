import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @AppStorage("sidecarDir") private var sidecarDir: String = SidecarManager.defaultSidecarDir
    @AppStorage("pythonPath") private var pythonPath: String = ""

    @State private var originField: String = ""

    // HDRezka login
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var loggingIn = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("HDRezka account") {
                if state.isLoggedIn {
                    LabeledContent("Account") {
                        Text(state.loggedInEmail.isEmpty ? "Logged in" : state.loggedInEmail)
                            .foregroundStyle(.secondary)
                    }
                    Button("Log out", role: .destructive) { state.logout() }
                    Text("Logging in enables premium translations and higher resolutions where your account allows.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                    HStack {
                        Button("Log in") { logIn() }
                            .disabled(loggingIn || email.isEmpty || password.isEmpty)
                        if loggingIn { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let loginError {
                        Label(loginError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Your session cookies are stored in the macOS Keychain and sent to HDRezka only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

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

            Section("Proxy (for geo-restricted streaming)") {
                TextField("Proxy URL", text: $state.proxyURLString,
                          prompt: Text("socks5://user:pass@host:1080"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.pushProxyConfig() }
                Text("HDRezka's video CDN is geo-blocked in some regions. A SOCKS5/HTTP proxy in a "
                     + "permitted region routes scraping, playback and downloads through it. Many "
                     + "VPNs expose a SOCKS5 endpoint (PIA, NordVPN, Windscribe, Mullvad). Leave "
                     + "empty to go direct.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply proxy") { state.pushProxyConfig() }
                    Spacer()
                    Label(state.proxyEnabled ? "Proxy on" : "Direct",
                          systemImage: state.proxyEnabled ? "lock.shield" : "globe")
                        .font(.caption).foregroundStyle(state.proxyEnabled ? .green : .secondary)
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

    private func logIn() {
        loggingIn = true; loginError = nil
        Task {
            defer { loggingIn = false }
            do {
                try await state.login(email: email, password: password)
                password = ""
            } catch {
                loginError = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
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
