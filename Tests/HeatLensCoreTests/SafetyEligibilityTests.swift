import Darwin
import Foundation
import Testing
@testable import HeatLensCore

/// Pure `eligibility(of:)` checks on synthetic samples; nothing here signals anything.
@Suite("Stop eligibility")
struct SafetyEligibilityTests {
    let terminator = ProcessTerminator()

    private func sample(pid: Int32 = 4_242, owner: ProcessOwner = .currentUser, name: String = "node",
                        path: String? = "/usr/local/bin/node", access: DetailAccess = .available) -> ProcessSample {
        SyntheticSnapshots.process(pid: pid, owner: owner, name: name, executablePath: path, detailAccess: access)
    }

    private func denial(_ sample: ProcessSample) -> String? {
        if case .denied(let reason) = terminator.eligibility(of: sample) { return reason }
        return nil
    }

    @Test("Your own readable non-Apple process is eligible")
    func eligible() {
        #expect(terminator.eligibility(of: sample()) == .eligible)
        #expect(terminator.eligibility(of: sample(path: "/Users/someone/Developer/app/bin/server")) == .eligible)
    }

    @Test("pid 1 and pid 0 are denied", arguments: [Int32(1), 0])
    func lowPIDs(pid: Int32) throws {
        let reason = try #require(denial(sample(pid: pid)))
        #expect(reason.contains("PID \(pid)"))
    }

    @Test("HeatLens itself is denied")
    func selfDenied() throws {
        #expect(try #require(denial(sample(pid: getpid()))).contains("HeatLens itself"))
    }

    @Test("A root sample is denied", arguments: [ProcessOwner.root, .otherUser, .unknown])
    func notOwned(owner: ProcessOwner) throws {
        let reason = try #require(denial(sample(owner: owner)))
        #expect(!reason.isEmpty)
        if owner == .root { #expect(reason.contains("root")) }
    }

    @Test("Denylisted names are denied, even when owned and readable", arguments: [
        "kernel_task", "WindowServer", "launchd", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "coreaudiod", "mds", "mds_stores", "mdsync", "cfprefsd",
    ])
    func denylisted(name: String) throws {
        let reason = try #require(denial(sample(name: name, path: "/Users/someone/fake/\(name)")))
        #expect(reason.contains(name))
        #expect(reason.contains("part of macOS"))
    }

    @Test("A denylisted executable file name is denied under any process name")
    func denylistedExecutable() throws {
        #expect(try #require(denial(sample(name: "renamed", path: "/opt/x/WindowServer"))).contains("WindowServer"))
    }

    @Test("Apple binary paths are denied", arguments: [
        "/System/Library/CoreServices/Something.app/Contents/MacOS/Something",
        "/usr/libexec/someservice", "/usr/sbin/somed", "/sbin/somed", "/usr/bin/python3",
        "/bin/sleep", "/bin/zsh", "/bin/launchctl", "/Library/Apple/usr/bin/something",
    ])
    func applePaths(path: String) throws {
        #expect(try #require(denial(sample(name: "something", path: path))).contains("Apple system program"))
    }

    @Test("An unreadable executable path is denied", arguments: [String?.none, ""])
    func noPath(path: String?) throws {
        #expect(try #require(denial(sample(path: path))).contains("executable path"))
    }

    @Test("Unreadable details are denied", arguments: [DetailAccess.permissionDenied, .processExited, .notSupported])
    func detailAccess(access: DetailAccess) throws {
        let reason = try #require(denial(sample(access: access)))
        if access == .permissionDenied { #expect(reason.contains("identity can't be verified")) }
    }
}
