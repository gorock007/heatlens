import Foundation
import Testing
@testable import HeatLensCore

@Suite("Provenance resolver")
struct ProvenanceResolverTests {
    @Test("Next dev descendants stay with the package-runner root")
    func nextTreeGrouping() throws {
        let snapshot = SyntheticSnapshots.oldNextServer
        let groups = ProvenanceResolver.resolve(snapshot)
        let group = try #require(groups.first)

        #expect(groups.count == 1)
        #expect(group.root.pid == 300)
        #expect(group.members.map(\.pid) == [300, 301])
        #expect(group.kind == "next dev")
        #expect(group.project?.directory == SyntheticSnapshots.home + "/Developer/Portfolio")
        #expect(group.project?.basis == "cwd")
        #expect(!group.evidence.isEmpty)
    }

    @Test("Agent is a workload boundary beneath Superset and owns helper descendants")
    func agentBoundary() throws {
        let home = SyntheticSnapshots.home
        let snapshot = SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(pid: 700, name: "Superset", executablePath: "/Applications/Superset.app/Contents/MacOS/Superset", arguments: ["Superset"]),
            SyntheticSnapshots.process(pid: 701, parentPID: 700, name: "zsh", executablePath: "/bin/zsh", arguments: ["zsh"], currentDirectory: home + "/Developer/Agent"),
            SyntheticSnapshots.process(pid: 702, parentPID: 701, name: "claude.exe", executablePath: home + "/bin/claude", arguments: ["claude"], currentDirectory: home + "/Developer/Agent"),
            SyntheticSnapshots.process(pid: 703, parentPID: 702, name: "npm", executablePath: "/usr/local/bin/npm", arguments: ["npm", "exec", "invented-mcp"], currentDirectory: home + "/Developer/Agent"),
            SyntheticSnapshots.process(pid: 704, parentPID: 703, name: "helper", arguments: ["helper"], currentDirectory: home + "/Developer/Agent"),
        ])

        let groups = ProvenanceResolver.resolve(snapshot)
        let claude = try #require(groups.first(where: { $0.kind == "claude" }))
        #expect(claude.root.pid == 702)
        #expect(Set(claude.members.map(\.pid)) == Set([702, 703, 704]))
        #expect(groups.first(where: { $0.kind == "superset" }) != nil)
    }

    @Test("Unknown restricted process remains an Unknown project without crashing")
    func restrictedProcess() throws {
        let group = try #require(ProvenanceResolver.resolve(SyntheticSnapshots.restricted).first)
        #expect(group.kind == "unknown")
        #expect(group.project == nil)
        #expect(group.label.contains("Unknown project"))
        #expect(group.confidence == .low)
    }

    @Test("Project falls back to an absolute argv path when cwd is unavailable")
    func argvProjectFallback() throws {
        let process = SyntheticSnapshots.process(
            pid: 750,
            name: "node",
            arguments: ["node", SyntheticSnapshots.home + "/Developer/NoCwd/node_modules/.bin/next", "dev"],
            currentDirectory: nil
        )
        let group = try #require(ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([process])).first)
        #expect(group.kind == "next dev")
        #expect(group.project?.directory == SyntheticSnapshots.home + "/Developer/NoCwd/node_modules/.bin")
        #expect(group.project?.basis == "argv path")
        #expect(group.project?.confidence == .medium)
    }

    @Test("Bare Node is weak evidence, while the known Claude package path is recognized")
    func weakNodeAndClaudePackage() throws {
        let bareNode = SyntheticSnapshots.process(pid: 760, name: "node", executablePath: "/Applications/Raycast.app/Contents/node", arguments: ["node"])
        let claudePackage = SyntheticSnapshots.process(
            pid: 761,
            name: "node",
            arguments: ["node", SyntheticSnapshots.home + "/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
            currentDirectory: SyntheticSnapshots.home + "/Developer/Agent"
        )
        let groups = ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([bareNode, claudePackage]))
        #expect(groups.first(where: { $0.root.pid == 760 })?.kind == "app")
        #expect(groups.first(where: { $0.root.pid == 761 })?.kind == "claude")
    }

    @Test("Known argv tokens classify supported tools without substring guesses", arguments: [
        (["node", "/work/node_modules/.bin/vite"], "vite"),
        (["node", "/work/node_modules/.bin/astro"], "astro"),
        (["node", "/work/node_modules/.bin/webpack"], "webpack"),
        (["node", "/work/node_modules/.bin/turbo"], "turbo"),
        (["node", "/work/node_modules/.bin/vitest"], "vitest"),
        (["node", "/work/node_modules/.bin/jest"], "jest"),
        (["node", "/work/node_modules/.bin/tsc", "--watch"], "tsc --watch"),
    ])
    func toolTokens(arguments: [String], expected: String) throws {
        let process = SyntheticSnapshots.process(pid: 800, name: "node", arguments: arguments, currentDirectory: "/work")
        let group = try #require(ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([process])).first)
        #expect(group.kind == expected)
    }
}
