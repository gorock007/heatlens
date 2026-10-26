import Testing
@testable import HeatLensCore

@Suite("MachTimebase")
struct MachTimebaseTests {
    @Test("Apple Silicon 125/3 timebase: 24 ticks = 1 µs")
    func appleSilicon() {
        let tb = MachTimebase(numer: 125, denom: 3)
        #expect(tb.nanoseconds(fromTicks: 24) == 1_000)
        #expect(tb.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
    }

    @Test("Intel 1/1 timebase is the identity")
    func intel() {
        #expect(MachTimebase(numer: 1, denom: 1).nanoseconds(fromTicks: 123_456_789) == 123_456_789)
    }

    @Test("large tick counts do not overflow")
    func noOverflow() {
        let tb = MachTimebase(numer: 125, denom: 3)
        // ~2 years of 24 MHz ticks: ticks * 125 would overflow 64 bits.
        let ticks: UInt64 = 24_000_000 * 86_400 * 730
        #expect(tb.nanoseconds(fromTicks: ticks) == 1_000_000_000 * 86_400 * 730)
    }

    @Test("zero denominator is clamped rather than trapping")
    func zeroDenom() {
        #expect(MachTimebase(numer: 5, denom: 0).nanoseconds(fromTicks: 2) == 10)
    }
}

@Suite("CPUMath")
struct CPUMathTests {
    @Test("delta of process counters")
    func delta() {
        let before = CPUTime(userNanoseconds: 1_000, systemNanoseconds: 500)
        let after = CPUTime(userNanoseconds: 4_000, systemNanoseconds: 1_500)
        #expect(CPUMath.delta(before: before, after: after) == CPUTime(userNanoseconds: 3_000, systemNanoseconds: 1_000))
    }

    @Test("a counter that went backwards (pid reuse) yields nil, never a negative")
    func reuse() {
        let before = CPUTime(userNanoseconds: 9_000, systemNanoseconds: 0)
        let after = CPUTime(userNanoseconds: 10, systemNanoseconds: 0)
        #expect(CPUMath.delta(before: before, after: after) == nil)
    }

    @Test("100% means one core; multi-core work exceeds 100")
    func percent() {
        let second: UInt64 = 1_000_000_000
        #expect(CPUMath.percentOfOneCore(cpuNanoseconds: 5 * second, elapsedNanoseconds: 5 * second) == 100)
        #expect(CPUMath.percentOfOneCore(cpuNanoseconds: 15 * second, elapsedNanoseconds: 5 * second) == 300)
        #expect(CPUMath.percentOfOneCore(cpuNanoseconds: second / 2, elapsedNanoseconds: 5 * second) == 10)
        #expect(CPUMath.percentOfMachine(cpuNanoseconds: 11 * second, elapsedNanoseconds: second, coreCount: 11) == 100)
    }

    @Test("zero elapsed or zero cores gives 0, not a division trap")
    func zeroElapsed() {
        #expect(CPUMath.percentOfOneCore(cpuNanoseconds: 5, elapsedNanoseconds: 0) == 0)
        #expect(CPUMath.percentOfMachine(cpuNanoseconds: 5, elapsedNanoseconds: 5, coreCount: 0) == 0)
    }

    @Test("Mach ticks to CPUTime via timebase")
    func fromTicks() {
        let t = CPUTime(userTicks: 24_000, systemTicks: 48_000, timebase: MachTimebase(numer: 125, denom: 3))
        #expect(t.userNanoseconds == 1_000_000)
        #expect(t.systemNanoseconds == 2_000_000)
        #expect(t.totalNanoseconds == 3_000_000)
    }

    @Test("host load ticks: busy fraction and delta")
    func loadTicks() {
        let before = CPULoadTicks(user: 100, system: 50, idle: 850, nice: 0)
        let after = CPULoadTicks(user: 300, system: 150, idle: 1_050, nice: 0)
        let d = CPUMath.delta(before: before, after: after)
        #expect(d == CPULoadTicks(user: 200, system: 100, idle: 200, nice: 0))
        #expect(d?.busyFraction == 0.6)
        #expect(CPULoadTicks(user: 0, system: 0, idle: 0, nice: 0).busyFraction == 0)
        #expect(CPUMath.delta(before: after, after: before) == nil)
        #expect((before + after).total == 2_500)
    }
}
