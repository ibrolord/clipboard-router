// SYNTHETIC STAND-IN for the Clipboard Router app, used only by Scripts/mcp/harness.
// Compiled together with the production Sources/ClipboardRouterAgentAccess/*.swift (no copy).
// It serves three hard-coded synthetic clips and one synthetic Vault item. It never reads the
// real clipboard, Vault, Keychain, CloudKit or any account data.
//
// Logging is deliberately content-free: wall-clock ISO timestamp + AgentAccessEvent lines
// (reason codes and monotonic milliseconds). Titles, texts, purposes and client names are
// never written.
//
// Modes:
//   --pairing approve|deny|never   how a new pairing is decided (default approve)
//   --vault approve|deny           how a Vault request is decided (default approve)
//   --pairing-timeout SECONDS      shortens TransportLimits.pairingTimeout (use with `never`)
//   --run-seconds SECONDS          self-terminate after this long (default 300)
//   --spoof-listen PATH            TEST ONLY: skip identity resolution, bind PATH with
//                                  LocalSocket.listen, accept one connection, count bytes.

import Darwin
import Foundation

final class FixtureLog: @unchecked Sendable {
    static let shared = FixtureLog()
    private let lock = NSLock()

    static func wallClock() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var seconds = tv.tv_sec
        var parts = tm()
        gmtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S", &parts)
        let stamp = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return stamp + String(format: ".%03dZ", Int(tv.tv_usec) / 1000)
    }

    func line(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data((Self.wallClock() + " " + text + "\n").utf8))
    }
}

struct SyntheticClip {
    var id: UUID
    var title: String
    var text: String
}

enum SyntheticData {
    static let included = SyntheticClip(
        id: UUID(uuidString: "5A1C0DE0-0000-4000-8000-00000000000A")!,
        title: "CR-SYNTHETIC-TITLE-ALPHA",
        text: "CR-SYNTHETIC-CANARY-7f3a"
    )
    static let includedSecond = SyntheticClip(
        id: UUID(uuidString: "5A1C0DE0-0000-4000-8000-00000000000B")!,
        title: "CR-SYNTHETIC-TITLE-BRAVO",
        text: "CR-SYNTHETIC-SECOND-4e8d"
    )
    /// Exists in the fixture's library but is NOT in the shared scope.
    static let excluded = SyntheticClip(
        id: UUID(uuidString: "5A1C0DE0-0000-4000-8000-00000000000C")!,
        title: "CR-SYNTHETIC-TITLE-EXCLUDED",
        text: "CR-SYNTHETIC-EXCLUDED-b05c"
    )
    static let all = [included, includedSecond, excluded]
    static let vaultText = "CR-SYNTHETIC-VAULT-91c2"
    static let modifiedAt: Int64 = 1_700_000_000
}

final class FixtureBackend: AgentAccessBackend {
    private let authority: AgentAccessAuthority
    private let pairing: String
    private let vault: String

    init(authority: AgentAccessAuthority, pairing: String, vault: String) {
        self.authority = authority
        self.pairing = pairing
        self.vault = vault
    }

    func listSharedClips(_ channel: ReleaseChannel, limit: Int) async -> ReleaseOutcome {
        channel.release { scope in
            let rows = SyntheticData.all
                .filter { scope.savedClipIDs.contains($0.id) }
                .prefix(limit)
                .map {
                    SharedClipSummary(
                        id: $0.id.uuidString,
                        title: $0.title,
                        kind: .text,
                        byteCount: $0.text.utf8.count,
                        modifiedAtEpochSeconds: SyntheticData.modifiedAt
                    )
                }
            return .sharedClips(Array(rows))
        }
    }

    func getSharedClip(_ channel: ReleaseChannel, id: String) async -> ReleaseOutcome {
        channel.release { scope in
            // Excluded and nonexistent ids take exactly the same path and result.
            guard let uuid = UUID(uuidString: id),
                  scope.savedClipIDs.contains(uuid),
                  let clip = SyntheticData.all.first(where: { $0.id == uuid })
            else { return .failure(.notFound) }
            return .sharedClip(SharedClipContent(id: clip.id.uuidString, kind: .text, text: clip.text))
        }
    }

    func syncStatus(_ channel: ReleaseChannel) async -> ReleaseOutcome {
        channel.release { _ in
            .syncStatus(SyncStatusReport(
                snapshotReady: true,
                sync: .disabled,
                lastProjection: .notAppliedThisLaunch,
                lastProjectionAtEpochSeconds: nil
            ))
        }
    }

    func vaultRequestOpened(_ info: VaultRequestInfo) async {
        // info.purpose / info.displayName are never logged.
        switch vault {
        case "approve":
            let outcome = authority.releaseVault(info.key) {
                VaultHandoff(kind: .text, text: SyntheticData.vaultText)
            }
            FixtureLog.shared.line("fixture_vault_decision=approve outcome=\(outcome)")
        default:
            let denied = authority.denyVaultRequest(info.key)
            FixtureLog.shared.line("fixture_vault_decision=deny applied=\(denied)")
        }
    }

    func pairingRequested(_ info: AgentAccessSessionInfo) async {
        switch pairing {
        case "approve":
            let applied = authority.decidePairing(info.id, approve: true)
            FixtureLog.shared.line("fixture_pairing_decision=approve applied=\(applied)")
        case "deny":
            let applied = authority.decidePairing(info.id, approve: false)
            FixtureLog.shared.line("fixture_pairing_decision=deny applied=\(applied)")
        default:
            FixtureLog.shared.line("fixture_pairing_decision=none")
        }
    }
}

struct Options {
    var pairing = "approve"
    var vault = "approve"
    var runSeconds = 300.0
    var pairingTimeout: Double?
    var spoofPath: String?

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var index = 1
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--pairing":
                guard let v = value(), ["approve", "deny", "never"].contains(v) else { return nil }
                options.pairing = v
            case "--vault":
                guard let v = value(), ["approve", "deny"].contains(v) else { return nil }
                options.vault = v
            case "--run-seconds":
                guard let v = value(), let n = Double(v), n > 0 else { return nil }
                options.runSeconds = n
            case "--pairing-timeout":
                guard let v = value(), let n = Double(v), n > 0 else { return nil }
                options.pairingTimeout = n
            case "--spoof-listen":
                guard let v = value() else { return nil }
                options.spoofPath = v
            default:
                return nil
            }
            index += 1
        }
        return options
    }
}

enum Spoof {
    /// TEST ONLY. Stands in for an unsandboxed process that tries to occupy the app's
    /// endpoint. It does no identity resolution, accepts one connection and counts the bytes
    /// the connecting peer sends before closing.
    static func run(path: String, seconds: Double) -> Never {
        let log = FixtureLog.shared
        let directory = (path as NSString).deletingLastPathComponent
        let fd: Int32
        do {
            try LocalSocket.preparePrivateDirectory(directory)
            fd = try LocalSocket.listen(at: path)
        } catch {
            log.line("spoof_listen_failed reason=\(BrokerConnectionHandler.reason(error)) detail=\(error)")
            exit(4)
        }
        log.line("spoof_listening")
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(seconds * 1000)) > 0 else {
            log.line("spoof_no_connection")
            exit(5)
        }
        let client = accept(fd, nil, nil)
        guard client >= 0 else {
            log.line("spoof_accept_failed errno=\(errno)")
            exit(6)
        }
        log.line("spoof_connection_accepted")
        let deadline = MonotonicDeadline.after(3)
        var total = 0
        var sawEOF = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !deadline.hasPassed {
            var readPoll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readPoll, 1, Int32(max(deadline.remaining, 0) * 1000))
            if ready <= 0 { break }
            let count = read(client, &buffer, buffer.count)
            if count > 0 {
                total += count
            } else if count == 0 {
                sawEOF = true
                break
            } else if errno != EINTR && errno != EAGAIN {
                break
            }
        }
        log.line("spoof_bytes_received=\(total) eof=\(sawEOF)")
        close(client)
        close(fd)
        unlink(path)
        exit(0)
    }
}

enum Fixture {
    static func main() -> Never {
        let log = FixtureLog.shared
        guard let options = Options.parse(CommandLine.arguments) else {
            log.line("fixture_usage_error")
            exit(2)
        }
        log.line("fixture_start pid=\(getpid()) pairing=\(options.pairing) vault=\(options.vault)")
        log.line("fixture_container home=\(NSHomeDirectory())")
        if let path = options.spoofPath {
            Spoof.run(path: path, seconds: options.runSeconds)
        }

        let context: AppIdentityContext
        do {
            context = try AppIdentityContext.resolve(bundle: .main)
        } catch {
            let reason = (error as? AgentAccessIdentityError)?.reasonCode ?? "unexpected_error"
            log.line("fixture_identity_failed reason=\(reason)")
            exit(3)
        }
        log.line("fixture_identity_ok")

        var limits = TransportLimits.standard
        if let timeout = options.pairingTimeout { limits.pairingTimeout = timeout }
        let authority = AgentAccessAuthority(limits: limits)
        authority.setEnabled(true)
        authority.setScope(AgentAccessScope(savedClipIDs: [SyntheticData.included.id, SyntheticData.includedSecond.id]))
        let policy = context.clientPolicy
        let handler = BrokerConnectionHandler(
            limits: limits,
            authority: authority,
            backend: FixtureBackend(authority: authority, pairing: options.pairing, vault: options.vault),
            authenticate: { fd in try CodeIdentityVerifier.authenticate(fd, policy: policy) },
            log: { FixtureLog.shared.line($0.line) }
        )
        let listener = AgentAccessListener(handler: handler)
        do {
            try listener.start(endpoint: context.endpoint)
        } catch {
            log.line("fixture_listen_failed reason=\(BrokerConnectionHandler.reason(error))")
            exit(5)
        }
        log.line("fixture_listening socket=\(context.endpoint.socketPath)")

        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            listener.stop()
            FixtureLog.shared.line("fixture_stopped reason=sigterm")
            exit(0)
        }
        terminate.resume()
        let expiry = DispatchSource.makeTimerSource(queue: .main)
        expiry.schedule(deadline: .now() + options.runSeconds)
        expiry.setEventHandler {
            listener.stop()
            FixtureLog.shared.line("fixture_stopped reason=run_seconds")
            exit(0)
        }
        expiry.resume()
        dispatchMain()
    }
}

Fixture.main()
