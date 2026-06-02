import Foundation
import Combine

/// Spawns and supervises the Python sidecar that does all HDRezka scraping.
///
/// The app launches `server.py` on 127.0.0.1 with port 0 (OS-assigned), reads the
/// `SIDECAR_READY host=.. port=..` line it prints, and then talks to it over HTTP.
/// A random per-launch token is passed via env and required on every request.
@MainActor
final class SidecarManager: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    /// Shared secret required by the sidecar (X-Auth-Token header).
    let token = UUID().uuidString

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdinPipe: Pipe?

    var baseURL: URL? {
        if case .ready(let port) = state {
            return URL(string: "http://127.0.0.1:\(port)")
        }
        return nil
    }

    // MARK: Resolved paths (overridable in Settings)

    static var defaultSidecarDir: String {
        if let v = UserDefaults.standard.string(forKey: "sidecarDir"), !v.isEmpty { return v }
        // Dev default: the repo's sidecar folder.
        return "/Users/rinatmaltsev/Documents/Python Projects/media-player-mac-app/media-player-mac-app/sidecar"
    }

    private var sidecarDir: String { Self.defaultSidecarDir }

    private var pythonPath: String {
        if let v = UserDefaults.standard.string(forKey: "pythonPath"), !v.isEmpty { return v }
        let venv = (sidecarDir as NSString).appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: venv) { return venv }
        return "/usr/bin/env"   // will resolve `python3` from PATH
    }

    private var serverScript: String {
        (sidecarDir as NSString).appendingPathComponent("server.py")
    }

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        guard FileManager.default.fileExists(atPath: serverScript) else {
            state = .failed("Sidecar not found at \(serverScript). Set the path in Settings.")
            return
        }
        state = .starting

        let proc = Process()
        let py = pythonPath
        if py == "/usr/bin/env" {
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = ["python3", serverScript, "--port", "0"]
        } else {
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = [serverScript, "--port", "0"]
        }
        var env = ProcessInfo.processInfo.environment
        env["REZKA_SIDECAR_TOKEN"] = token
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let out = Pipe(); let err = Pipe(); let inn = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        // We keep the write end of stdin open; if the app dies, it closes and the
        // sidecar's stdin watchdog sees EOF and exits (no orphaned Python).
        proc.standardInput = inn
        self.stdoutPipe = out
        self.stderrPipe = err
        self.stdinPipe = inn

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleStdout(line) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                self?.process = nil
                if case .ready = self?.state {
                    self?.state = .failed("Helper exited (code \(p.terminationStatus)).")
                } else if case .starting = self?.state {
                    self?.state = .failed("Helper failed to start (code \(p.terminationStatus)).")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
        } catch {
            state = .failed("Could not launch Python: \(error.localizedDescription)")
        }
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process = nil
        stdinPipe = nil
        state = .stopped
    }

    /// Restart, e.g. after the user changes the sidecar path in Settings.
    func restart() {
        stop()
        start()
    }

    private func handleStdout(_ chunk: String) {
        for line in chunk.split(separator: "\n") {
            if line.hasPrefix("SIDECAR_READY") {
                // SIDECAR_READY host=127.0.0.1 port=54321
                if let portTok = line.split(separator: " ").first(where: { $0.hasPrefix("port=") }),
                   let port = Int(portTok.dropFirst("port=".count)) {
                    self.state = .ready(port: port)
                }
            }
        }
    }
}
