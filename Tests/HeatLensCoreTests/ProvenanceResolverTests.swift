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
        #expect(groups.first(where: { $0.kind == "app" && $0.label == "Superset" }) != nil)
    }

    @Test("Unknown restricted process remains low confidence without putting project text in its label")
    func restrictedProcess() throws {
        let group = try #require(ProvenanceResolver.resolve(SyntheticSnapshots.restricted).first)
        #expect(group.kind == "unknown")
        #expect(group.project == nil)
        #expect(group.label == "Unclassified background processes")
        #expect(!group.label.contains("Unknown project"))
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
        #expect(group.project?.directory == SyntheticSnapshots.home + "/Developer/NoCwd")
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

    @Test("Library, system, temporary, hidden, root and home paths are never projects", arguments: [
        SyntheticSnapshots.home + "/Library/Containers/com.example.Editor/Data",
        "/Library/Application Support/Example",
        "/System/Library/Example",
        "/private/var/folders/example",
        "/var/folders/example",
        "/tmp/example",
        "/usr/local/share/example",
        "/Applications/Example.app",
        "/opt/homebrew/Cellar/example",
        "/",
        SyntheticSnapshots.home,
        SyntheticSnapshots.home + "/Developer/.cache/example",
    ])
    func excludedProjectDirectories(path: String) throws {
        let process = SyntheticSnapshots.process(
            pid: 810,
            name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node"],
            currentDirectory: path
        )
        let group = try #require(ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([process])).first)
        #expect(group.project == nil)
    }

    @Test("Superset project and worktree paths remain valid and stop at meaningful roots")
    func supersetProjectExceptions() {
        let home = SyntheticSnapshots.home
        let snapshot = SyntheticSnapshots.snapshot([
            SyntheticSnapshots.process(
                pid: 820,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/.superset/projects/Orchard/scripts/worker.js"],
                currentDirectory: home + "/.superset/projects/Orchard/scripts"
            ),
            SyntheticSnapshots.process(
                pid: 821,
                name: "node",
                executablePath: "/usr/local/bin/node",
                arguments: ["node", home + "/.superset/worktrees/HeatLens/feature-a/scripts/worker.js"],
                currentDirectory: home + "/.superset/worktrees/HeatLens/feature-a/scripts"
            ),
        ])
        let projects = Set(ProvenanceResolver.resolve(snapshot).compactMap(\.project?.directory))
        #expect(projects == Set([
            home + "/.superset/projects/Orchard",
            home + "/.superset/worktrees/HeatLens/feature-a",
        ]))
    }

    @Test("Processes in one app bundle group together even when launchd parented; a known browser is kind browser")
    func appBundleGrouping() throws {
        let groups = ProvenanceResolver.resolve(SyntheticSnapshots.appBundleFamily)
        let chrome = try #require(groups.first(where: { $0.label == "Google Chrome" }))

        #expect(chrome.kind == "browser")
        #expect(Set(chrome.members.map(\.pid)) == Set([830, 831, 832]))
        #expect(chrome.project == nil)
        #expect(chrome.confidence == .high)
        #expect(!chrome.evidence.isEmpty)
    }

    @Test("Apple services collapse except protected and hot processes")
    func systemServiceGrouping() throws {
        let groups = ProvenanceResolver.resolve(SyntheticSnapshots.systemServiceFamily)
        let services = try #require(groups.first(where: { $0.label == "macOS system services" }))

        #expect(Set(services.members.map(\.pid)) == Set([840, 841, 842]))
        #expect(groups.first(where: { $0.label == "kernel_task" })?.members.map(\.pid) == [843])
        #expect(groups.first(where: { $0.label == "WindowServer" })?.members.map(\.pid) == [844])
        #expect(groups.first(where: { $0.label == "hot-service" })?.members.map(\.pid) == [845])
        #expect(groups.first(where: { $0.label == "macOS user services" })?.members.map(\.pid) == [846])
    }

    @Test("Labels are workload names, never project placeholders or paths")
    func nameOnlyLabels() throws {
        let worker = SyntheticSnapshots.process(
            pid: 850,
            name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", SyntheticSnapshots.home + "/Developer/Orchard/worker.js"],
            currentDirectory: SyntheticSnapshots.home + "/Developer/Orchard"
        )
        let groups = ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([worker]))
        let group = try #require(groups.first)

        #expect(group.label == "node worker.js")
        #expect(!group.label.contains("Unknown project"))
        #expect(!group.label.contains("Orchard"))
        #expect(group.project?.directory == SyntheticSnapshots.home + "/Developer/Orchard")
        #expect(!group.evidence.isEmpty)
    }

    @Test("A PID reused mid-scan (exited process plus its successor) groups without crashing; the live one wins")
    func reusedPID() throws {
        let old = SyntheticSnapshots.process(pid: 42, ageHours: 5, name: "old", detailAccess: .processExited)
        let new = SyntheticSnapshots.process(pid: 42, ageHours: 0.0001, name: "node", executablePath: "/usr/local/bin/node",
                                             arguments: ["node", SyntheticSnapshots.home + "/Developer/app/worker.js"],
                                             currentDirectory: SyntheticSnapshots.home + "/Developer/app", cpu: 40)
        for order in [[old, new], [new, old]] {
            let groups = ProvenanceResolver.resolve(SyntheticSnapshots.snapshot(order))
            let members = groups.flatMap(\.members)
            #expect(members == [new.identity])
        }
    }
}

