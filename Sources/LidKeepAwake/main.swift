import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import CoreGraphics

// MARK: - Power helpers

enum PowerSource {
    case ac, battery, unknown

    static var current: PowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let raw = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? else {
            return .unknown
        }
        switch raw {
        case kIOPSACPowerValue: return .ac
        case kIOPSBatteryPowerValue: return .battery
        default: return .unknown
        }
    }
}

/// Wraps calls to `pmset`, which is the only supported way to survive a
/// clamshell (lid-closed) sleep. `caffeinate` and IOKit wake assertions do
/// NOT prevent lid-close sleep — only `pmset disablesleep` does.
///
/// Timers are enforced *by root*, not by this app: enabling with a timer asks
/// for the admin password once and starts a detached root job that turns
/// sleep back on when the timer fires. That is why the revert needs no
/// password later, and why it still happens if the app is quit.
enum SleepCtl {
    /// Root-owned (mode 700) scratch dir, created by the elevated command.
    static let jobDir = "/var/tmp/lidkeepawake"

    static func isSleepDisabled() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        // macOS 13+ prints: " SleepDisabled\t\t1" in the System-wide section,
        // older releases printed " (sleepdisabled)         1". Match both,
        // case-insensitively.
        for line in text.split(separator: "\n") where line.lowercased().contains("sleepdisabled") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let last = parts.last, last == "1" { return true }
        }
        return false
    }

    /// Hardware clamshell (lid) state, read in-process from the power-management
    /// root domain — no subprocess, so it is cheap enough to poll every second.
    /// `nil` when the sensor isn't present (e.g. desktop Macs).
    static var isLidClosed: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return value as? Bool
    }

    /// Declares user activity, which wakes the display. Used on lid-open so the
    /// screen lights up the way it normally does (sleep is disabled, so macOS
    /// does not always restore the display on its own).
    @discardableResult
    static func wakeDisplay() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-u", "-t", "1"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Turns the display off. Safe and unprivileged.
    @discardableResult
    static func sleepDisplayNow() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Live display power state, read in-process (no subprocess, no polling
    /// cost). This is what lets the app *verify* the screen really is off.
    static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    // MARK: Root shells

    /// Cancels any pending timer job, then blocks system sleep. When
    /// `timerSeconds` is given, also starts a detached root job that restores
    /// sleep after that many seconds — unless the job has been superseded.
    static func enableShell(timerSeconds: Int?) -> String {
        var cmd = "/bin/mkdir -p \(jobDir) && /bin/chmod 700 \(jobDir)"
        cmd += "; /bin/kill $(/bin/cat \(jobDir)/pid 2>/dev/null) 2>/dev/null"
        cmd += "; /bin/rm -f \(jobDir)/gen.* \(jobDir)/pid"
        cmd += "; /usr/bin/pmset -a disablesleep 1"
        if let secs = timerSeconds {
            // A generation marker makes stale jobs harmless: if the marker is
            // gone (cancelled, or a newer session started), the job does nothing.
            let gen = "\(jobDir)/gen.\(Int(Date().timeIntervalSince1970))"
            cmd += "; /usr/bin/touch \(gen)"
            cmd += "; nohup /bin/sh -c '/bin/sleep \(secs); if [ -f \(gen) ]; then /usr/bin/pmset -a disablesleep 0; fi; /bin/rm -f \(gen) \(jobDir)/pid' >/dev/null 2>&1 & /bin/echo $! > \(jobDir)/pid"
        }
        return cmd
    }

    /// Restores normal sleep and kills any pending timer job.
    static func disableShell() -> String {
        "/bin/kill $(/bin/cat \(jobDir)/pid 2>/dev/null) 2>/dev/null"
        + "; /bin/rm -f \(jobDir)/gen.* \(jobDir)/pid"
        + "; /usr/bin/pmset -a disablesleep 0"
    }

    /// Cancels the timer but leaves the Mac awake indefinitely.
    static func cancelTimerShell() -> String {
        "/bin/kill $(/bin/cat \(jobDir)/pid 2>/dev/null) 2>/dev/null"
        + "; /bin/rm -f \(jobDir)/gen.* \(jobDir)/pid"
    }

    /// Runs a shell command as root. First tries passwordless sudo (fast path,
    /// no prompt), then falls back to an admin password dialog.
    /// Returns nil on success, or a human-readable error message.
    static func runElevated(shell: String) async -> String? {
        // Fast path: cached sudo credentials (cannot prompt this way).
        let sudo = Process()
        sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        sudo.arguments = ["-n", "/bin/sh", "-c", shell]
        sudo.standardOutput = Pipe()
        sudo.standardError = Pipe()
        if (try? sudo.run()) != nil {
            sudo.waitUntilExit()
            if sudo.terminationStatus == 0 { return nil }
        }

        // Slow path: AppleScript admin prompt.
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", script]
        osa.standardOutput = Pipe()
        let err = Pipe()
        osa.standardError = err
        do {
            try osa.run()
            osa.waitUntilExit()
            if osa.terminationStatus == 0 { return nil }
            let msg = (String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("-128") { return "Password dialog cancelled." }
            return msg.isEmpty ? "pmset failed (exit code \(osa.terminationStatus))." : msg
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - VS Code helpers

enum VSCode {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").isEmpty ||
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCodeInsiders").isEmpty
    }

    @discardableResult
    static func launch() -> Bool {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
                return true
            }
        }
        // Last resort: look for the usual install path.
        let path = "/Applications/Visual Studio Code.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return true
        }
        return false
    }
}

// MARK: - SSH keepalive

/// Keeping the Mac awake stops the *local* side from sleeping, but an idle
/// SSH/Remote-SSH connection can still be reaped by NAT routers, VPNs or
/// firewalls. ServerAliveInterval makes the client send periodic keepalives
/// so the mapping is never considered idle.
enum SSHKeepalive {
    static let marker = "# >>> LidKeepAwake keepalive >>>"

    static let block = """
    # >>> LidKeepAwake keepalive >>>
    Host *
        ServerAliveInterval 15
        ServerAliveCountMax 4
        TCPKeepAlive yes
    # <<< LidKeepAwake keepalive <<<
    """

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    /// True if *any* ServerAliveInterval exists — ours or the user's own.
    static var isConfigured: Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.contains("ServerAliveInterval") ?? false
    }

    static var isOurs: Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.contains(marker) ?? false
    }

    /// Appends the managed block. Never touches a config that already sets
    /// ServerAliveInterval, and backs up the original first.
    @discardableResult
    static func install() -> String? {
        let fm = FileManager.default
        var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""

        if text.contains("ServerAliveInterval") {
            return nil // respect the user's existing keepalive settings
        }

        let dir = configURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            return "Could not create ~/.ssh: \(error.localizedDescription)"
        }

        if fm.fileExists(atPath: configURL.path) {
            let backup = dir.appendingPathComponent("config.lidkeepawake.bak")
            if !fm.fileExists(atPath: backup.path) {
                try? fm.copyItem(at: configURL, to: backup)
            }
        }

        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\n" + block + "\n"

        do {
            try text.write(to: configURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            return "Could not write ~/.ssh/config: \(error.localizedDescription)"
        }
        return nil
    }
}

// MARK: - Diagnostics

/// Append-only log at /tmp/lidkeepawake.log. Deliberately trivial: it exists
/// so you can confirm after reopening the lid that the screen was off and the
/// system never slept.
enum Diag {
    static let path = "/tmp/lidkeepawake.log"

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Timer presets

enum TimerPreset: String, CaseIterable, Identifiable {
    case fifteenMinutes = "15 min"
    case thirtyMinutes = "30 min"
    case oneHour = "1 hour"
    case twoHours = "2 hours"
    case fourHours = "4 hours"
    case eightHours = "8 hours"
    case custom = "Custom"

    var id: String { rawValue }

    var seconds: Int? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .custom: return nil
        }
    }
}

// MARK: - View model

@MainActor
final class AppState: ObservableObject {
    @Published var sleepDisabled = false
    @Published var powerSource: PowerSource = .unknown
    @Published var vscodeRunning = false
    @Published var busy = false
    @Published var statusMessage: String?
    @Published var autoRevertOnBattery = true
    @Published var sshKeepaliveConfigured = false
    /// Live hardware lid state (nil when the Mac has no lid sensor).
    @Published var lidClosed: Bool?
    /// Live display power state (true = panel is off).
    @Published var displayAsleep = false

    // Timer page
    @Published var selectedPreset: TimerPreset = .oneHour
    @Published var customHours = 1
    @Published var customMinutes = 0
    /// Deadline of the running timer; nil when no timer is active.
    @Published private(set) var timerEnd: Date?
    /// Total length of the running timer, used for the progress bar.
    @Published private(set) var timerTotal: TimeInterval = 0
    /// Bumped once a second so countdown views re-render.
    @Published private(set) var clock = Date()

    private var pollTimer: Timer?
    private var tickCount = 0
    private var previousPowerSource: PowerSource = .unknown
    /// Previous lid state, so we can act on the close transition only.
    private var lidWasClosed = false
    /// Throttles forced display-sleep requests.
    private var lastDisplayEnforce = Date.distantPast
    /// Set once we have forced the panel off for the current lid-closed session.
    private var didForceDisplayOff = false
    /// How many times the panel was woken again during the current closed session.
    private var wakesWhileClosed = 0
    private var hintedAboutHID = false

    private static let timerEndKey = "timerEnd"
    private static let timerTotalKey = "timerTotal"

    init() {
        if let stored = UserDefaults.standard.object(forKey: Self.timerEndKey) as? Double {
            let end = Date(timeIntervalSince1970: stored)
            if end > Date() {
                timerEnd = end
                timerTotal = UserDefaults.standard.double(forKey: Self.timerTotalKey)
            }
        }
        refresh()
        // 1 s tick drives the countdown; system state is re-read every 5th tick
        // so we spawn pmset at the same rate as before.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        pollTimer?.tolerance = 0.5
    }

    // MARK: Timer maths

    var remaining: TimeInterval? {
        guard let end = timerEnd else { return nil }
        return max(0, end.timeIntervalSince(clock))
    }

    var hasActiveTimer: Bool { remaining != nil }

    var countdownText: String? {
        guard let remaining else { return nil }
        let total = Int(remaining.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Compact form for the menu bar, e.g. "42m", "1h04m".
    var menuBarCountdown: String? {
        guard let remaining else { return nil }
        let total = Int(remaining.rounded())
        if total >= 3600 { return String(format: "%dh%02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }

    /// Seconds the Timer page would start with.
    var pendingSeconds: Int {
        if let fixed = selectedPreset.seconds { return fixed }
        return max(60, customHours * 3600 + customMinutes * 60)
    }

    var pendingDescription: String { Self.describe(seconds: pendingSeconds) }

    static func describe(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        switch (h, m) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return h == 1 ? "1 hour" : "\(h) hours"
        default: return "\(h) h \(m) min"
        }
    }

    // MARK: Polling

    private func onTick() {
        clock = Date()
        tickCount += 1

        if let end = timerEnd, end <= Date() {
            // The root job has already restored sleep; just update our UI.
            timerEnd = nil
            persistTimerEnd()
            statusMessage = "Timer finished — system sleep restored automatically."
            Diag.log("timer expired → system sleep restored by root job")
        }

        // Lid + display are cheap in-process reads, so check every second.
        displayAsleep = SleepCtl.isDisplayAsleep
        updateLidState()
        enforceDisplayOffIfNeeded()

        if tickCount % 5 == 0 { refresh() }
    }

    /// Lid transitions. Closing: force the screen off, keep the system running.
    /// Opening: behave like a normal Mac — the screen comes back on, and nothing
    /// is forced in either direction.
    private func updateLidState() {
        let state = SleepCtl.isLidClosed
        lidClosed = state
        let closed = state ?? false

        if closed && !lidWasClosed {
            Diag.log("lid CLOSED (mode \(sleepDisabled ? "ON" : "off"), display asleep: \(SleepCtl.isDisplayAsleep))")
            if sleepDisabled {
                enforceDisplayOffIfNeeded()
                statusMessage = "Lid closed — screen off, VS Code and SSH keep running."
            } else {
                statusMessage = "Lid closed — lid-closed mode is off, so the Mac will sleep."
            }
        } else if !closed && lidWasClosed {
            Diag.log("lid OPEN (display asleep: \(SleepCtl.isDisplayAsleep))")
            didForceDisplayOff = false
            wakesWhileClosed = 0
            hintedAboutHID = false
            if sleepDisabled && SleepCtl.isDisplayAsleep {
                SleepCtl.wakeDisplay()
                displayAsleep = SleepCtl.isDisplayAsleep
                Diag.log("lid open → woke display (asleep now: \(displayAsleep))")
            }
            statusMessage = sleepDisabled
                ? "Lid open — normal use; close it again any time."
                : "Lid open — normal use."
        }
        lidWasClosed = closed
    }

    /// The core requirement: lid closed + mode on ⇒ screen off, system awake.
    /// The lid switch normally does this in hardware; if something (a display
    /// assertion, a stale wake) leaves the panel lit, re-assert it.
    private func enforceDisplayOffIfNeeded() {
        guard lidClosed == true, sleepDisabled else { return }
        guard !displayAsleep else { return }
        // The panel being lit while we believe the lid is shut is suspicious —
        // a freshly opened lid can outrun the poll. Re-read the sensor before
        // touching the display so we never blank a screen that should be on.
        if let fresh = SleepCtl.isLidClosed, fresh == false {
            lidClosed = false
            lidWasClosed = false
            Diag.log("panel lit but lid is actually OPEN — corrected state, not forcing display")
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastDisplayEnforce) >= 1 else { return }
        lastDisplayEnforce = now

        // Do NOT re-read the display state here: `pmset displaysleepnow` returns
        // before the panel has actually powered down, so an immediate read always
        // reports "awake" and made the log lie. The 1 s tick below picks up the
        // real state.
        if didForceDisplayOff {
            // We already blanked the panel this session and it is lit again —
            // something woke it. A Bluetooth/USB input device lights the display
            // on any event, even with the lid shut.
            wakesWhileClosed += 1
            Diag.log("panel woken again while lid closed (wake #\(wakesWhileClosed)) — external input? re-forcing display sleep")
            if wakesWhileClosed >= 3 && !hintedAboutHID {
                hintedAboutHID = true
                Diag.log("hint: an external input device (Bluetooth/USB mouse, keyboard or gamepad) wakes the display on any event. Disconnect it to keep the panel dark.")
                statusMessage = "Screen keeps waking — an external input device (Bluetooth mouse?) is doing it. Disconnect it for a dark screen."
            }
        } else {
            Diag.log("lid closed + mode on → forcing display sleep")
            didForceDisplayOff = true
        }
        SleepCtl.sleepDisplayNow()
    }

    func refresh() {
        let newSource = PowerSource.current
        let switchedToBattery = (newSource == .battery && previousPowerSource == .ac)
        previousPowerSource = newSource
        powerSource = newSource
        vscodeRunning = VSCode.isRunning
        sshKeepaliveConfigured = SSHKeepalive.isConfigured
        let disabled = SleepCtl.isSleepDisabled()
        if disabled != sleepDisabled {
            sleepDisabled = disabled
            if !disabled {
                // The mode went off outside of our action (timer job, external
                // pmset, auto-revert) — drop the closed-session counters.
                didForceDisplayOff = false
                wakesWhileClosed = 0
                hintedAboutHID = false
            }
        }

        // Safety net: only when the Mac *drops* from AC to battery while the
        // mode is active — not when the user chose to enable it on battery.
        if sleepDisabled && switchedToBattery && autoRevertOnBattery {
            Task { await setSleepDisabled(false, announce: "Unplugged — reverted to normal sleep to protect against overheating.") }
        }
    }

    // MARK: Actions

    func setSleepDisabled(_ on: Bool, announce: String? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let errorText = await SleepCtl.runElevated(
            shell: on ? SleepCtl.enableShell(timerSeconds: nil) : SleepCtl.disableShell()
        )
        if errorText == nil {
            sleepDisabled = on
            if !on {
                clearTimer()
                didForceDisplayOff = false
                wakesWhileClosed = 0
                hintedAboutHID = false
            }
            Diag.log("mode \(on ? "ENABLED" : "DISABLED") by user (power: \(powerSource == .ac ? "AC" : "battery"))")
            statusMessage = announce ?? (on
                ? "Enabled — close the lid whenever you like: screen off, VS Code keeps running."
                : "Disabled — normal sleep restored.")
        } else {
            statusMessage = on ? "Could not enable: \(errorText!)" : "Could not disable: \(errorText!)"
        }
        refresh()
    }

    /// Enables lid-closed mode with a root-side countdown that restores sleep
    /// on its own when it expires.
    func startTimer() async {
        guard !busy else { return }
        let seconds = pendingSeconds
        busy = true
        defer { busy = false }
        let errorText = await SleepCtl.runElevated(shell: SleepCtl.enableShell(timerSeconds: seconds))
        if errorText == nil {
            sleepDisabled = true
            timerTotal = TimeInterval(seconds)
            timerEnd = Date().addingTimeInterval(TimeInterval(seconds))
            persistTimerEnd()
            statusMessage = "Timer started: awake for \(Self.describe(seconds: seconds)). Auto-reverts on its own."
        } else {
            statusMessage = "Could not start timer: \(errorText!)"
        }
        refresh()
    }

    /// Stops the countdown. Optionally also restores normal sleep.
    func stopTimer(andSleep: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let errorText = await SleepCtl.runElevated(
            shell: andSleep ? SleepCtl.disableShell() : SleepCtl.cancelTimerShell()
        )
        if errorText == nil {
            clearTimer()
            if andSleep { sleepDisabled = false }
            statusMessage = andSleep
                ? "Timer cancelled — normal sleep restored."
                : "Timer cancelled — staying awake until you turn it off."
        } else {
            statusMessage = "Could not cancel timer: \(errorText!)"
        }
        refresh()
    }

    func installSSHKeepalive() {
        if let err = SSHKeepalive.install() {
            statusMessage = err
        } else {
            statusMessage = SSHKeepalive.isOurs
                ? "SSH keepalive added to ~/.ssh/config. New terminals use it automatically."
                : "You already have SSH keepalive settings — left untouched."
        }
        refresh()
    }

    private func clearTimer() {
        timerEnd = nil
        timerTotal = 0
        persistTimerEnd()
    }

    private func persistTimerEnd() {
        if let end = timerEnd {
            UserDefaults.standard.set(end.timeIntervalSince1970, forKey: Self.timerEndKey)
            UserDefaults.standard.set(timerTotal, forKey: Self.timerTotalKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.timerEndKey)
            UserDefaults.standard.removeObject(forKey: Self.timerTotalKey)
        }
    }
}

// MARK: - UI

struct MenuView: View {
    @EnvironmentObject var app: AppState
    @State private var page: Page = .status

    enum Page: String, CaseIterable, Identifiable {
        case status = "Status"
        case timer = "Timer"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            switch page {
            case .status: statusPage
            case .timer: timerPage
            }

            if app.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting…").foregroundStyle(.secondary)
                }
            } else if let msg = app.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                Spacer()
                Text(app.sleepDisabled ? "⚠︎ Don't put your Mac in a bag while awake" : "")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Insomnia", systemImage: app.sleepDisabled ? "bolt.fill" : "moon.zzz.fill")
                .font(.headline)
            Spacer()
            if let countdown = app.countdownText {
                Label(countdown, systemImage: "timer")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Status page

    @ViewBuilder
    private var statusPage: some View {
        statusRow(icon: "power", title: "Power",
                  detail: app.powerSource == .battery ? "Battery" : (app.powerSource == .ac ? "AC power" : "Unknown"),
                  ok: app.powerSource == .ac)

        statusRow(icon: "chevron.left.forwardslash.chevron.right", title: "VS Code",
                  detail: app.vscodeRunning ? "Running" : "Not running",
                  ok: app.vscodeRunning)

        statusRow(icon: "powersleep", title: "System sleep",
                  detail: app.sleepDisabled ? "Blocked — stays running" : "Normal",
                  ok: app.sleepDisabled)

        statusRow(icon: "display", title: "Display",
                  detail: !app.sleepDisabled
                      ? "Normal"
                      : (app.displayAsleep ? "Off — verified" : "On (forcing off…)"),
                  ok: !app.sleepDisabled ? true : app.displayAsleep)

        if let lidClosed = app.lidClosed {
            statusRow(icon: lidClosed ? "laptopcomputer" : "laptopcomputer.slash",
                      title: "Lid",
                      detail: lidClosed
                          ? (app.sleepDisabled ? "Closed — running" : "Closed — will sleep")
                          : "Open",
                      ok: lidClosed ? app.sleepDisabled : true)
        }

        statusRow(icon: "network", title: "SSH keepalive",
                  detail: app.sshKeepaliveConfigured ? "Configured" : "Not set",
                  ok: app.sshKeepaliveConfigured)

        Divider()

        Toggle("Keep running when lid is closed", isOn: Binding(
            get: { app.sleepDisabled },
            set: { newValue in
                Task { await app.setSleepDisabled(newValue) }
            }
        ))
        .toggleStyle(.switch)
        .disabled(app.busy)
        .help("Disables system sleep so background apps like VS Code survive lid close. Blocking sleep needs an admin password; restoring it needs one too.")

        Text("Close the lid any time: the screen goes off and VS Code + SSH keep running in the background.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if app.powerSource == .battery && !app.sleepDisabled {
            Label("On battery: closing the lid with apps running can cause overheating. Plug in if you can.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle("Auto-revert if I unplug", isOn: $app.autoRevertOnBattery)
            .toggleStyle(.checkbox)

        if !app.sshKeepaliveConfigured {
            Button {
                app.installSSHKeepalive()
            } label: {
                Label("Set up SSH keepalive", systemImage: "network")
            }
            .buttonStyle(.borderless)
            .help("Adds ServerAliveInterval to ~/.ssh/config so Remote-SSH sessions survive idle NAT/firewall timeouts. Your config is backed up first.")
        }

        if !app.vscodeRunning {
            Button {
                VSCode.launch()
            } label: {
                Label("Launch VS Code", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Timer page

    @ViewBuilder
    private var timerPage: some View {
        if let remaining = app.remaining, let countdown = app.countdownText {
            VStack(alignment: .leading, spacing: 8) {
                Text(countdown)
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .center)

                Label("Sleep auto-restores when this hits zero — no password needed.",
                      systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ProgressView(value: progressValue(remaining: remaining))
                    .progressViewStyle(.linear)

                Button {
                    Task { await app.stopTimer(andSleep: false) }
                } label: {
                    Label("Cancel timer, stay awake", systemImage: "bolt.fill")
                }
                .disabled(app.busy)

                Button {
                    Task { await app.stopTimer(andSleep: true) }
                } label: {
                    Label("Stop and sleep normally", systemImage: "moon.zzz.fill")
                }
                .disabled(app.busy)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep awake for")
                    .font(.callout)

                Picker("", selection: $app.selectedPreset) {
                    ForEach(TimerPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if app.selectedPreset == .custom {
                    Stepper("Hours: \(app.customHours)", value: $app.customHours, in: 0...23)
                        .font(.callout)
                    Stepper("Minutes: \(app.customMinutes)", value: $app.customMinutes, in: 0...59)
                        .font(.callout)
                }

                Button {
                    Task { await app.startTimer() }
                } label: {
                    Label("Start — awake for \(app.pendingDescription)", systemImage: "timer")
                }
                .disabled(app.busy)

                Text("Asks for your admin password once. When the timer ends the Mac goes back to sleeping normally, even if this app is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressValue(remaining: TimeInterval) -> Double {
        let total = app.timerTotal
        guard total > 0 else { return 0 }
        return max(0, min(1, remaining / total))
    }

    @ViewBuilder
    private func statusRow(icon: String, title: String, detail: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16)
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

// MARK: - App

@main
struct LidKeepAwakeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(app)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: app.sleepDisabled ? "bolt.fill" : "moon.zzz.fill")
                if let countdown = app.menuBarCountdown {
                    Text(countdown).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
