import Foundation
import Testing
@testable import HeatLensCore

@Suite("ProcessIdentity")
struct ProcessIdentityTests {
    @Test("same pid, same start time is the same process")
    func equality() {
        let a = ProcessIdentity(pid: 4242, startSeconds: 1_792_995_077, startMicroseconds: 87_897)
        let b = ProcessIdentity(pid: 4242, startTimeMicros: 1_792_995_077_087_897)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("a reused pid with a new start time is a different process")
    func pidReuse() {
        let old = ProcessIdentity(pid: 4242, startSeconds: 1_792_995_077, startMicroseconds: 0)
        let new = ProcessIdentity(pid: 4242, startSeconds: 1_792_995_078, startMicroseconds: 0)
        #expect(old != new)
    }

    @Test("start date and uptime round-trip; uptime never negative")
    func dates() {
        let id = ProcessIdentity(pid: 1, startSeconds: 1_000, startMicroseconds: 500_000)
        #expect(id.startDate == Date(timeIntervalSince1970: 1_000.5))
        #expect(id.uptime(at: Date(timeIntervalSince1970: 1_010.5)) == 10)
        #expect(id.uptime(at: Date(timeIntervalSince1970: 900)) == 0)
    }

    @Test("Codable round-trip keeps the identity exact")
    func codable() throws {
        let id = ProcessIdentity(pid: 99_999, startTimeMicros: 1_792_995_077_087_897)
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(ProcessIdentity.self, from: data) == id)
    }
}
