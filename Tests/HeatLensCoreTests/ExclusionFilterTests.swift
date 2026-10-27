import Foundation
import Testing
@testable import HeatLensCore

@Suite("Exclusion filter")
struct ExclusionFilterTests {
    let home = SyntheticSnapshots.home

    @Test("Process names match exactly, ignoring case")
    func processNames() {
        let filter = ExclusionFilter(processNames: ["Node"])
        #expect(filter.excludes(processName: "node", projectDirectory: nil))
        #expect(filter.excludes(processName: "NODE", projectDirectory: nil))
        #expect(!filter.excludes(processName: "nodemon", projectDirectory: nil))
        #expect(!filter.excludes(processName: nil, projectDirectory: nil))
    }

    @Test("Project prefixes match the folder and its children, on a path boundary")
    func projectPrefixes() {
        let filter = ExclusionFilter(projectPrefixes: [home + "/Developer/demo"])
        #expect(filter.excludes(processName: nil, projectDirectory: home + "/Developer/demo"))
        #expect(filter.excludes(processName: nil, projectDirectory: home + "/Developer/demo/web"))
        #expect(!filter.excludes(processName: nil, projectDirectory: home + "/Developer/demo-two"))
        #expect(!filter.excludes(processName: nil, projectDirectory: home + "/Developer"))
        #expect(!filter.excludes(processName: nil, projectDirectory: nil))
    }

    @Test("A trailing slash and dot segments in the prefix don't change the match")
    func standardizedPrefix() {
        let filter = ExclusionFilter(projectPrefixes: [home + "/Developer/./demo/"])
        #expect(filter.excludes(processName: nil, projectDirectory: home + "/Developer/demo/web"))
        #expect(!filter.excludes(processName: nil, projectDirectory: home + "/Developer/demo-two"))
    }

    @Test("A ~ prefix expands to the home folder")
    func tildePrefix() {
        let filter = ExclusionFilter(projectPrefixes: ["~/Projects/demo"])
        #expect(filter.excludes(processName: nil, projectDirectory: NSHomeDirectory() + "/Projects/demo/app"))
        #expect(!filter.excludes(processName: nil, projectDirectory: "/Projects/demo/app"))
    }

    @Test("Excluded findings drop out, system findings stay, order is kept")
    func visibleFindings() throws {
        let snapshot = SyntheticSnapshots.snapshot(
            SyntheticSnapshots.hotVitestAndIdleWorker.processes, thermal: .serious)
        let groups = ProvenanceResolver.resolve(snapshot)
        let findings = RulesEngine().evaluate(snapshot, groups: groups)
        #expect(findings.contains { $0.kind == .highCPU })
        #expect(findings.contains { $0.kind == .thermal })

        let none = ExclusionFilter().visibleFindings(findings, snapshot: snapshot, groups: groups)
        #expect(none.map(\.id) == findings.map(\.id))

        let filter = ExclusionFilter(projectPrefixes: [home + "/Developer/Tests"])
        let visible = filter.visibleFindings(findings, snapshot: snapshot, groups: groups)
        #expect(!visible.contains { $0.kind == .highCPU })
        #expect(visible.contains { $0.kind == .thermal })
        #expect(visible.map(\.id) == findings.filter { $0.kind != .highCPU }.map(\.id))
    }
}
