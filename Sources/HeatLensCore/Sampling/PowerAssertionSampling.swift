import Foundation
import IOKit.pwr_mgt

/// Sleep-blocking power assertions found at one instant, for the processes a scan saw.
public struct PowerAssertionReading: Sendable {
    /// Only processes holding at least one sleep-blocking assertion, sorted by PID.
    public let assertions: [ProcessPowerAssertions]
    /// Why the read failed, for a notice; nil when it worked.
    public let failure: String?
    /// `CLOCK_UPTIME_RAW` time the read took, for docs/PERFORMANCE.md and the probe.
    public let elapsedNanoseconds: UInt64

    public init(assertions: [ProcessPowerAssertions], failure: String? = nil, elapsedNanoseconds: UInt64 = 0) {
        self.assertions = assertions
        self.failure = failure
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

public protocol PowerAssertionSampling: Sendable {
    /// One read of the sleep-blocking assertions held by `processes`.
    func powerAssertions(of processes: [ProcessReading]) -> PowerAssertionReading
}

/// Reads every assertion with the public `IOPMCopyAssertionsByProcess` (one call, under a
/// millisecond) and keeps the sleep-blocking ones held by processes in the reading.
public struct IOKitPowerAssertionSampler: PowerAssertionSampling {
    public init() {}

    public func powerAssertions(of processes: [ProcessReading]) -> PowerAssertionReading {
        let started = ProcessCounters.monotonicNow()
        var unmanaged: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&unmanaged)
        guard result == kIOReturnSuccess, let byPID = unmanaged?.takeRetainedValue() as NSDictionary? else {
            return PowerAssertionReading(assertions: [], failure: String(format: "IOPMCopyAssertionsByProcess returned 0x%08x", result),
                                         elapsedNanoseconds: ProcessCounters.monotonicNow() - started)
        }
        var raw: [Int32: [[String: Any]]] = [:]
        for (key, value) in byPID {
            guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [[String: Any]] else { continue }
            raw[pid] = list
        }
        return PowerAssertionReading(assertions: PowerAssertionParsing.assertions(raw, processes: processes),
                                     elapsedNanoseconds: ProcessCounters.monotonicNow() - started)
    }
}

/// Pure filtering and attribution, so they are testable without live assertions.
enum PowerAssertionParsing {
    // Dictionary keys: IOPMLib.h names the first three; the rest are what
    // `IOPMCopyAssertionsByProcess` returns on macOS 14+ (checked against `pmset -g assertions`).
    static let typeKey = "AssertType"            // kIOPMAssertionTypeKey
    static let nameKey = "AssertName"            // kIOPMAssertionNameKey
    static let timeoutKey = "TimeoutSeconds"     // kIOPMAssertionTimeoutKey
    static let levelKey = "AssertLevel"          // kIOPMAssertionLevelKey: 0 off, 255 on
    static let startKey = "AssertStartWhen"
    static let onBehalfKey = "AssertionOnBehalfOfPID"

    /// nil unless the dictionary is a sleep-blocking assertion that is on.
    static func assertion(_ raw: [String: Any]) -> (assertion: PowerAssertion, onBehalfOf: Int32?)? {
        guard let type = raw[typeKey] as? String, SleepEffect(assertionType: type) != nil else { return nil }
        if let level = raw[levelKey] as? NSNumber, level.intValue == 0 { return nil }
        let timeout = (raw[timeoutKey] as? NSNumber)?.doubleValue
        let assertion = PowerAssertion(type: type, name: raw[nameKey] as? String ?? "",
                                       startedAt: raw[startKey] as? Date,
                                       timeoutSeconds: timeout.flatMap { $0 > 0 ? $0 : nil })
        return (assertion, (raw[onBehalfKey] as? NSNumber)?.int32Value)
    }

    /// Keeps the sleep-blocking assertions of PIDs in `processes`, attributed to the process
    /// they serve:
    /// - one created on another process's behalf (coreaudiod for a player) belongs to that
    ///   process when it is in the reading, with `createdByPID` naming the creator;
    /// - powerd's own assertions ("prevent sleep while display is on") mirror the display's
    ///   state rather than cause it, so they are dropped;
    /// - an assertion that started more than a second before its process did belongs to an
    ///   earlier owner of a reused PID, so it is dropped.
    static func assertions(_ raw: [Int32: [[String: Any]]], processes: [ProcessReading]) -> [ProcessPowerAssertions] {
        let byPID = Dictionary(processes.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [ProcessIdentity: [PowerAssertion]] = [:]
        for (pid, list) in raw {
            guard let holder = byPID[pid] else { continue }
            for dictionary in list {
                guard let parsed = Self.assertion(dictionary) else { continue }
                var owner = holder
                var assertion = parsed.assertion
                if let onBehalfOf = parsed.onBehalfOf, onBehalfOf != pid, let beneficiary = byPID[onBehalfOf] {
                    owner = beneficiary
                    assertion = PowerAssertion(type: assertion.type, name: assertion.name, startedAt: assertion.startedAt,
                                               timeoutSeconds: assertion.timeoutSeconds, createdByPID: pid)
                } else if holder.name == "powerd" {
                    continue
                }
                if let start = assertion.startedAt, start < owner.identity.startDate.addingTimeInterval(-1) { continue }
                found[owner.identity, default: []].append(assertion)
            }
        }
        return found.map { identity, assertions in
            ProcessPowerAssertions(identity: identity, assertions: assertions.sorted {
                ($0.startedAt ?? .distantFuture, $0.type, $0.name) < ($1.startedAt ?? .distantFuture, $1.type, $1.name)
            })
        }.sorted { $0.identity.pid < $1.identity.pid }
    }
}
