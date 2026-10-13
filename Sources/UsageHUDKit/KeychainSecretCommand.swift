import Foundation

/// Reads Claude Code's sign-in from the login Keychain through `/usr/bin/security`.
///
/// Claude Code writes its Keychain item with `security`, so the item's access list already
/// trusts that tool: reading through it shows no prompt, and the grant does not depend on
/// UsageHUD's own code signature (a rebuilt or re-signed UsageHUD reads it the same way).
///
/// The tool runs from a fixed absolute path with an argument array (no shell). Its standard
/// input is closed, its standard error discarded, and its standard output (the item's secret)
/// is captured into memory only: it is parsed, then the buffer is zeroed. No secret is ever on a
/// command line, in a log line or in an error message: failures map from the exit status to
/// fixed messages.
public enum KeychainSecretCommand {
    public static let executable = URL(fileURLWithPath: "/usr/bin/security")

    /// The one command UsageHUD runs.
    public struct Invocation: Equatable, Sendable {
        public let executable: URL
        public let arguments: [String]

        /// `security find-generic-password -s <service> -a <account> -w`: prints the item's secret.
        public static func findClaudeCredentials(service: String, account: String) -> Invocation {
            Invocation(executable: KeychainSecretCommand.executable,
                       arguments: ["find-generic-password", "-s", service, "-a", account, "-w"])
        }

        /// Tests only: another program, to exercise the runner's timeout and exit statuses.
        init(executable: URL, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// How a run ended. The output is the secret; it never leaves this file except parsed.
    struct Outcome {
        var status: Int32
        var output: Data
        var timedOut: Bool
        var launched: Bool
    }

    /// Exit statuses `security` uses: the low byte of the Security framework's `OSStatus`.
    enum ExitStatus {
        static let itemNotFound: Int32 = 44          // errSecItemNotFound
        static let interactionNotAllowed: Int32 = 36 // errSecInteractionNotAllowed
        static let authFailed: Int32 = 51            // errSecAuthFailed
        static let userCanceled: Int32 = 128         // errSecUserCanceled
    }

    /// Runs `invocation` and turns its result into a lookup. `timeout` bounds the wait: a run
    /// that has not finished by then is stopped and reads as needing the owner (a tool that
    /// waits is waiting on a prompt).
    public static func read(_ invocation: Invocation, timeout: TimeInterval) -> CredentialLookup<ClaudeToken> {
        var outcome = run(invocation, timeout: timeout)
        defer { outcome.output.resetBytes(in: 0..<outcome.output.count) }
        return lookup(outcome)
    }

    /// The exit status's meaning. Only a clean exit is parsed; every failure is a fixed message.
    static func lookup(_ outcome: Outcome) -> CredentialLookup<ClaudeToken> {
        guard outcome.launched else { return .failed("Couldn't run /usr/bin/security") }
        if outcome.timedOut { return .needsApproval }
        switch outcome.status {
        case 0:
            return ClaudeToken.parse(outcome.output).map { .found($0) }
                ?? .failed("Claude Code's sign-in is in a format UsageHUD can't read")
        case ExitStatus.itemNotFound:
            return .missing
        case ExitStatus.interactionNotAllowed, ExitStatus.authFailed, ExitStatus.userCanceled:
            return .needsApproval
        default:
            return .failed("The Keychain read failed (security exited \(outcome.status))")
        }
    }

    /// Runs the tool with stdin closed and stderr discarded, collecting stdout without
    /// blocking, and stops it at `timeout` (SIGTERM, then SIGKILL a second later). The wait is
    /// bounded even when something else keeps the pipe open after the tool exits.
    static func run(_ invocation: Invocation, timeout: TimeInterval) -> Outcome {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Outcome(status: -1, output: Data(), timedOut: false, launched: false)
        }
        let fd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        defer { buffer.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) } }
        var endOfFile = false
        func drain() {
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { output.append(buffer, count: count) } else { endOfFile = count == 0; return }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        while true {
            var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pending, 1, 50)
            drain()
            if !process.isRunning {
                if endOfFile { break }
                // Exited, but the pipe is still open elsewhere: a short grace, then stop reading.
                if let exitedAt { if Date().timeIntervalSince(exitedAt) > 0.5 { break } } else { exitedAt = Date() }
            } else if Date() > deadline {
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
                return Outcome(status: process.terminationStatus, output: output, timedOut: true, launched: true)
            }
        }
        exited.wait()
        return Outcome(status: process.terminationStatus, output: output, timedOut: false, launched: true)
    }
}
