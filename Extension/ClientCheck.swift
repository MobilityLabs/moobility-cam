import CoreMediaIO
import Darwin
import Foundation
import os

/// Decides who may write frames into the camera. Reading it is what call apps do, and macOS's
/// camera permission governs that, but only the installed app, signed by this team, may feed it.
///
/// Forks change `appBundleID` and `installedExecutable`. The team is read from the extension's own signature.
enum ClientCheck {
    static let appBundleID = "com.mobilitylabs.MoobilityCam"
    static let installedExecutable = "/Applications/MoobilityCam.app/Contents/MacOS/MoobilityCam"

    private static let log = Logger(subsystem: "com.mobilitylabs.MoobilityCam.Extension", category: "ClientCheck")

    /// False on any error. Asks the kernel about the running process, because the sandbox denies the Security
    /// framework's checks (they re-read the file from disk), and a file-read exception crashes the extension at
    /// launch. `client.signingID` isn't used: macOS reports "unknown" for every client here.
    ///
    /// The team and identity are what the signature claims, and the kernel doesn't check who issued it, so a
    /// hand-built signature could claim them. The path closes that: the kernel reports where the process really
    /// runs from, and macOS's App Management protection stops another developer's app replacing a notarized app
    /// there. The hardened runtime requirement stops other code being loaded into the real process.
    static func isOurApp(_ client: CMIOExtensionClient) -> Bool {
        let pid = client.pid
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            log.error("refused pid \(pid, privacy: .public): no executable path (\(errno, privacy: .public))")
            return false
        }
        let executable = String(cString: path)
        guard executable == installedExecutable else {
            log.error("refused pid \(pid, privacy: .public): runs from \(executable, privacy: .public)")
            return false
        }
        guard let flags = KernelSignature.flags(of: pid) else {
            log.error("refused pid \(pid, privacy: .public): no signature status")
            return false
        }
        guard flags & KernelSignature.valid != 0, flags & KernelSignature.adhoc == 0,
              flags & KernelSignature.hardenedRuntime != 0 else {
            log.error("refused pid \(pid, privacy: .public): signature flags \(String(flags, radix: 16), privacy: .public)")
            return false
        }
        guard let ownTeam = KernelSignature.teamID(of: getpid()) else {
            log.error("refused pid \(pid, privacy: .public): can't read this extension's team")
            return false
        }
        let team = KernelSignature.teamID(of: pid)
        let identity = KernelSignature.identity(of: pid)
        guard team == ownTeam, identity == appBundleID else {
            log.error("refused pid \(pid, privacy: .public): \(identity ?? "no identity", privacy: .public) from team \(team ?? "none", privacy: .public)")
            return false
        }
        return true
    }
}

/// The kernel's record of a running process's signature. `csops` is exported by libSystem but has no public
/// header. There's no public API that works inside this sandbox.
private enum KernelSignature {
    static let valid: UInt32 = 0x1              // CS_VALID
    static let adhoc: UInt32 = 0x2              // CS_ADHOC
    static let hardenedRuntime: UInt32 = 0x10000  // CS_RUNTIME

    private static let opsStatus: UInt32 = 0    // CS_OPS_STATUS
    private static let opsIdentity: UInt32 = 11 // CS_OPS_IDENTITY
    private static let opsTeamID: UInt32 = 14   // CS_OPS_TEAMID
    private static let blobHeaderSize = 8       // magic, then big-endian total length

    static func flags(of pid: pid_t) -> UInt32? {
        var flags: UInt32 = 0
        return csops(pid, opsStatus, &flags, MemoryLayout<UInt32>.size) == 0 ? flags : nil
    }

    static func identity(of pid: pid_t) -> String? { blobString(pid, opsIdentity) }
    static func teamID(of pid: pid_t) -> String? { blobString(pid, opsTeamID) }

    private static func blobString(_ pid: pid_t, _ operation: UInt32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 512)
        let status = buffer.withUnsafeMutableBytes { csops(pid, operation, $0.baseAddress, $0.count) }
        guard status == 0 else { return nil }
        let length = Int(buffer[4]) << 24 | Int(buffer[5]) << 16 | Int(buffer[6]) << 8 | Int(buffer[7])
        guard length > blobHeaderSize, length <= buffer.count else { return nil }
        return String(decoding: buffer[blobHeaderSize..<length].prefix { $0 != 0 }, as: UTF8.self)
    }
}

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ operation: UInt32, _ address: UnsafeMutableRawPointer?, _ size: Int) -> Int32
