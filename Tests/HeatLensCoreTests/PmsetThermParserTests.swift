import Testing
@testable import HeatLensCore

@Suite("PmsetThermParser")
struct PmsetThermParserTests {
    let appleSiliconSample = """
    Note: No thermal warning level has been recorded
    Note: No performance warning level has been recorded
    2026-10-26 17:30:00 +0300
    CPU Power notify
    \tCPU_Scheduler_Limit \t= 100
    \tCPU_Available_CPUs \t= 11
    \tCPU_Speed_Limit \t= 100
    """

    @Test("parses the limit keys and keeps the rest as notes")
    func parse() {
        let r = PmsetThermParser.parse(appleSiliconSample)
        #expect(r.cpuSchedulerLimit == 100)
        #expect(r.availableCPUs == 11)
        #expect(r.cpuSpeedLimit == 100)
        #expect(r.indicatesThrottling == false)
        #expect(r.notes.contains("Note: No thermal warning level has been recorded"))
        #expect(r.notes.contains("CPU Power notify"))
    }

    @Test("a limit below 100 indicates throttling")
    func throttled() {
        let r = PmsetThermParser.parse("CPU_Speed_Limit = 63\nCPU_Scheduler_Limit = 100")
        #expect(r.indicatesThrottling == true)
        #expect(r.cpuSpeedLimit == 63)
    }

    @Test("no limit keys: nothing is invented")
    func absent() {
        let r = PmsetThermParser.parse("Note: No thermal warning level has been recorded\n")
        #expect(r.isEmpty)
        #expect(r.indicatesThrottling == nil)
        #expect(r.cpuSpeedLimit == nil)
    }

    @Test("empty and odd input")
    func odd() {
        #expect(PmsetThermParser.parse("").isEmpty)
        let r = PmsetThermParser.parse("Some Key With Spaces = 5\n= 7\nKey = notanumber\nOK=42")
        #expect(r.values == ["OK": 42])
        #expect(r.notes.count == 3)
    }
}
