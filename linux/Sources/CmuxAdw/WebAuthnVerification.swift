import Foundation

/// S2: user verification, and the honesty that goes with it.
///
/// THE BUG THIS EXISTS FOR (hias' dogfood, 2026-09-10): the authenticator
/// set the UV flag on every ceremony while the consent gate obtained a
/// CLICK. UV is a claim about WHO is present — a PIN, a password, a
/// fingerprint. A click is presence. A relying party asking
/// `userVerification: "required"` therefore believed a second factor had
/// happened, and had no way to discover otherwise.
///
/// THE LADDER, strongest available per ceremony:
///     fprintd  -> fingerprint  -> UV=1, truthfully
///     polkit   -> password     -> UV=1, truthfully
///     none     -> click only   -> UV=0, truthfully
///
/// The bottom rung is the load-bearing one. A site demanding
/// `userVerification: "required"` will refuse a UV=0 credential, and that
/// refusal is CORRECT — it is the site saying "this setup cannot meet my
/// bar" on hardware with no reader. Being turned away honestly beats a
/// silent false claim the site cannot detect. And per CTAP semantics
/// (pk3's correction, taken over this desk's weaker proposal): an
/// authenticator that cannot verify does not answer a `required` ceremony
/// with UV=0 — it FAILS the ceremony up front. Returning UV=0 there would
/// outsource the honesty to the relying party's diligence.
///
/// MEASURED, not assumed (2026-09-10, this host):
///  - polkit has NO implicit default for an unregistered action. `pkcheck`
///    errors with "Action ... is not registered", so a `.policy` file is
///    not a fallback for the password rung — it is the only path to it.
///  - fprintd registers `net.reactivated.fprint.device.verify` ITSELF with
///    allow_active, and `pkcheck` on it returns authorized with no dialog.
///    So the FINGERPRINT rung needs no packaging at all; the PASSWORD rung
///    is the one that needs a one-time root install. That is the inverse
///    of what the lane's handover note assumed.
///  - inside flatpak neither is reachable today: the manifest grants no
///    system-bus name and there is no portal that authenticates a human.
///    `auto` therefore degrades to `.none` there by probing, with no
///    special case — which is exactly the "backend interface whose sandbox
///    answer is none" the verdict letter asked for.
enum WebAuthnVerification {

    enum Level: String {
        case none, fingerprint, password, test

        /// What a person is told, and what `webauthn status` reports.
        var sentence: String {
            switch self {
            case .fingerprint: return "verified by fingerprint"
            case .password: return "verified by password"
            case .test: return "verified by the test backend"
            case .none: return "no verification available — the site may refuse this"
            }
        }

        var verifiesUser: Bool { self != .none }
    }

    /// `CMUX_WEBAUTHN_UV_BACKEND` = none | fprintd | polkit | test | auto.
    /// Default `auto`: probe for the strongest rung that answers.
    static var configured: String {
        ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_UV_BACKEND"] ?? "auto"
    }

    /// The rung this instance can actually reach. Probed, never assumed —
    /// "a fingerprint reader exists" is not the same claim as "fprintd
    /// will answer us", and only the second one can back a UV bit.
    static func available() -> Level {
        switch configured {
        case "none": return .none
        case "test": return testBackendPermitted ? .test : .none
        case "fprintd": return fprintdReady() ? .fingerprint : .none
        case "polkit": return polkitReady() ? .password : .none
        default:
            if fprintdReady() { return .fingerprint }
            if polkitReady() { return .password }
            return .none
        }
    }

    /// Same gate S3 imposed on the consent bypass, for the same reason: a
    /// hatch that FAKES VERIFICATION is precisely the shape of the bug
    /// this file removes. It may only ever touch a vault a test created.
    private static var testBackendPermitted: Bool {
        let redirected = (ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_VAULT"]?
            .isEmpty == false)
        if !redirected, !refusalLogged {
            refusalLogged = true
            FileHandle.standardError.write(Data(
                ("cmux webauthn: test verifier ignored — CMUX_WEBAUTHN_UV_BACKEND=test "
                 + "requires an explicit CMUX_WEBAUTHN_VAULT pointing away from the default "
                 + "vault, so a faked verification can never apply to real credentials. "
                 + "Falling back to no verification.\n").utf8))
        }
        return redirected
    }

    private static var refusalLogged = false

    // MARK: - probes

    /// Enrolled fingers AND a reachable service. `fprintd-list` exits
    /// non-zero when the service cannot be reached, which is the answer we
    /// want inside a sandbox without a system-bus name.
    private static func fprintdReady() -> Bool {
        guard let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty else {
            return false
        }
        guard let out = run("fprintd-list", [user], timeout: 5) else { return false }
        return out.contains("- #")
    }

    /// Our own action must be REGISTERED; polkit does not fall back for an
    /// unknown one, it errors. `pkaction` answers this without prompting.
    private static func polkitReady() -> Bool {
        guard let out = run("pkaction", ["--action-id", polkitActionId], timeout: 5) else {
            return false
        }
        return out.contains(polkitActionId)
    }

    static let polkitActionId = "com.manaflow.cmux.webauthn.verify"

    // MARK: - the verification itself

    /// Asks the strongest available rung to verify the human. Answers on
    /// the main loop, asynchronously — like the consent dialog, and for
    /// the same reason: a real fingerprint takes as long as a finger does.
    static func verify(level: Level, rpId: String, completion: @escaping (Bool) -> Void) {
        switch level {
        case .none:
            completion(false)
        case .test:
            // Deliberately deferred rather than inline: an inline answer
            // would once again test a path no human takes.
            DispatchQueue.main.async { completion(true) }
        case .fingerprint:
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = run("fprintd-verify", [], timeout: 30)?
                    .contains("verify-match") ?? false
                DispatchQueue.main.async { completion(ok) }
            }
        case .password:
            DispatchQueue.global(qos: .userInitiated).async {
                // pkcheck prompts through the session's polkit agent; the
                // message the user sees comes from our .policy file, which
                // is why that file names the ceremony instead of an id.
                let ok = runExitZero("pkcheck", [
                    "--action-id", polkitActionId,
                    "--process", String(ProcessInfo.processInfo.processIdentifier),
                    "--allow-user-interaction",
                ], timeout: 120)
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    // MARK: - subprocess helpers (the house pattern: secret-tool, gdbus)

    /// The timeout is REAL, and it has to be. `fprintd-verify` waits for a
    /// finger; `pkcheck --allow-user-interaction` waits for a password.
    /// Neither ever returns on its own if nobody is at the machine, and a
    /// ceremony that hangs forever is a worse answer than one that says
    /// no. (First version of this file took a `timeout:` argument and
    /// ignored it — the parameter looked like a guarantee and was
    /// decoration, which is the same failure mode as a guard written in
    /// JavaScript that nobody calls.)
    private static func armWatchdog(_ process: Process, seconds: Int) -> DispatchWorkItem {
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + .seconds(seconds), execute: killer)
        return killer
    }

    private static func run(_ tool: String, _ args: [String], timeout: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let killer = armWatchdog(process, seconds: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func runExitZero(_ tool: String, _ args: [String], timeout: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let killer = armWatchdog(process, seconds: timeout)
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0
    }
}
