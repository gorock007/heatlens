import Foundation
import Testing
@testable import HeatLensCore

@Suite("Workload heuristics, user rules and process tree")
struct WorkloadHeuristicsTests {
    private let home = SyntheticSnapshots.home

    private func group(for process: ProcessSample, among others: [ProcessSample] = [], rules: [WorkloadRule] = []) throws -> ProcessGroup {
        let groups = ProvenanceResolver.resolve(SyntheticSnapshots.snapshot([process] + others), userRules: rules)
        return try #require(groups.first { $0.members.contains(process.identity) })
    }

    @Test("Python: script, -m module, and a bare interpreter")
    func python() throws {
        let script = SyntheticSnapshots.process(pid: 900, name: "python3.12", executablePath: "/opt/homebrew/bin/python3.12",
                                                arguments: ["python3.12", home + "/Developer/ml/train.py", "--epochs", "3"],
                                                currentDirectory: home + "/Developer/ml")
        let scriptGroup = try group(for: script)
        #expect(scriptGroup.kind == "python script" && scriptGroup.label == "python train.py")
        #expect(scriptGroup.project?.directory == home + "/Developer/ml")

        let module = SyntheticSnapshots.process(pid: 901, name: "python3", executablePath: "/usr/local/bin/python3",
                                                arguments: ["python3", "-m", "http.server", "8000"], currentDirectory: home + "/Developer/site")
        #expect(try group(for: module).label == "python -m http.server")
    }

    @Test("pytest is a test runner, like vitest")
    func pytest() throws {
        let process = SyntheticSnapshots.process(pid: 905, name: "python3", executablePath: "/usr/local/bin/python3",
                                                 arguments: ["python3", home + "/Developer/api/.venv/bin/pytest", "-x"],
                                                 currentDirectory: home + "/Developer/api")
        #expect(try group(for: process).kind == "pytest")
    }

    @Test("Java: -jar, Gradle and Kotlin daemons, and a plain main class after -cp")
    func java() throws {
        func label(_ arguments: [String], pid: Int32) throws -> String {
            try group(for: SyntheticSnapshots.process(pid: pid, name: "java", executablePath: "/usr/bin/java", arguments: arguments,
                                                      currentDirectory: home + "/Developer/jvm")).label
        }
        #expect(try label(["java", "-Xmx2g", "-jar", "/opt/tools/server.jar"], pid: 910) == "java server.jar")
        #expect(try label(["java", "-cp", "/x/gradle.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.10"], pid: 911) == "Gradle daemon")
        #expect(try label(["java", "-cp", "k.jar", "org.jetbrains.kotlin.daemon.KotlinCompileDaemon"], pid: 912) == "Kotlin daemon")
        #expect(try label(["java", "-classpath", "app.jar", "-Dx=1", "com.example.Main"], pid: 913) == "java Main")
    }

    @Test("Docker CLI is labelled by its subcommand")
    func dockerCLI() throws {
        let compose = SyntheticSnapshots.process(pid: 920, name: "docker", executablePath: "/usr/local/bin/docker",
                                                 arguments: ["docker", "--context", "default", "compose", "up"], currentDirectory: home + "/Developer/FDA")
        let composeGroup = try group(for: compose)
        #expect(composeGroup.kind == "docker cli" && composeGroup.label == "docker compose")
        let build = SyntheticSnapshots.process(pid: 921, name: "docker", executablePath: "/usr/local/bin/docker",
                                               arguments: ["docker", "build", "-t", "app", "."], currentDirectory: home + "/Developer/FDA")
        #expect(try group(for: build).label == "docker build")
    }

    @Test("Gemini CLI and Codex are coding agents, and a package runner under one joins its group")
    func agents() throws {
        let gemini = SyntheticSnapshots.process(pid: 930, name: "node", executablePath: "/opt/homebrew/bin/node",
                                                arguments: ["node", "/opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js"],
                                                currentDirectory: home + "/Developer/app")
        #expect(try group(for: gemini).kind == "gemini")
        let codex = SyntheticSnapshots.process(pid: 940, name: "codex", executablePath: "/opt/homebrew/bin/codex",
                                               arguments: ["codex", "exec", "fix the tests"], currentDirectory: home + "/Developer/app")
        let mcp = SyntheticSnapshots.process(pid: 941, parentPID: 940, name: "npm", executablePath: "/opt/homebrew/bin/npm",
                                             arguments: ["npm", "exec", "some-mcp"], currentDirectory: home + "/Developer/app")
        let codexGroup = try group(for: codex, among: [mcp])
        #expect(codexGroup.kind == "codex" && codexGroup.label == "Codex CLI")
        #expect(codexGroup.members.contains(mcp.identity))
    }

    @Test("Known browsers are kind browser and count as active work when busy")
    func browsers() throws {
        let arc = SyntheticSnapshots.process(pid: 950, name: "Arc", executablePath: "/Applications/Arc.app/Contents/MacOS/Arc", cpu: 80)
        let helper = SyntheticSnapshots.process(
            pid: 951, parentPID: 950, name: "Browser Helper (Renderer)",
            executablePath: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)",
            cpu: 30)
        let browser = try group(for: arc, among: [helper])
        #expect(browser.kind == "browser" && browser.label == "Arc" && browser.members.contains(helper.identity))
        let snapshot = SyntheticSnapshots.snapshot([arc, helper])
        let finding = try #require(RulesEngine().evaluate(snapshot, groups: ProvenanceResolver.resolve(snapshot)).first { $0.kind == .highCPU })
        #expect(finding.explanation.contains("looks like active work"))
    }

    @Test("A long-lived detached python worker is a review candidate, like a node worker")
    func pythonDetachedWorker() {
        let worker = SyntheticSnapshots.process(pid: 960, ageHours: 50, name: "python3", executablePath: "/usr/local/bin/python3",
                                                arguments: ["python3", home + "/Developer/scraper/worker.py"],
                                                currentDirectory: home + "/Developer/scraper", cpu: 0.1)
        let snapshot = SyntheticSnapshots.snapshot([worker])
        let findings = RulesEngine().evaluate(snapshot, groups: ProvenanceResolver.resolve(snapshot))
        #expect(findings.contains { $0.kind == .detachedWorker })
    }

    // MARK: User rules

    @Test("Rules parse one per line; comments and blanks are skipped; bad lines are reported")
    func ruleParsing() {
        let parsed = WorkloadRule.parse("""
        # my labels
        ffmpeg = Video encode

        my-worker.py=Scraper
        bad line without equals
        has space = Nope
        empty =
        FFMPEG = Duplicate token is dropped
        """)
        #expect(parsed.rules == [WorkloadRule(token: "ffmpeg", label: "Video encode")!, WorkloadRule(token: "my-worker.py", label: "Scraper")!])
        #expect(parsed.ignored == ["bad line without equals", "has space = Nope", "empty ="])
        #expect(WorkloadRule(token: String(repeating: "a", count: 65), label: "x") == nil)
        #expect(WorkloadRule(token: "a", label: "line\nbreak") == nil)
        let many = (0..<60).map { "tool\($0) = Tool \($0)" }.joined(separator: "\n")
        let capped = WorkloadRule.parse(many)
        #expect(capped.rules.count == WorkloadRule.maxRules && capped.ignored.count == 10)
    }

    @Test("A user rule beats the built-in heuristics and matches name, executable or argv token")
    func userRuleWins() throws {
        let rules = WorkloadRule.parse("vitest = Integration tests\nffmpeg = Video encode").rules
        let vitest = SyntheticSnapshots.process(pid: 970, name: "node", executablePath: "/usr/local/bin/node",
                                                arguments: ["node", home + "/Developer/app/node_modules/.bin/vitest", "run"],
                                                currentDirectory: home + "/Developer/app")
        let labelled = try group(for: vitest, rules: rules)
        #expect(labelled.kind == "custom" && labelled.label == "Integration tests")
        #expect(labelled.evidence.contains { $0.source == "Settings → Custom labels" })
        let ffmpeg = SyntheticSnapshots.process(pid: 971, name: "ffmpeg", executablePath: "/opt/homebrew/bin/ffmpeg",
                                                arguments: ["ffmpeg", "-i", "in.mov", "out.mp4"], currentDirectory: home + "/Movies")
        #expect(try group(for: ffmpeg, rules: rules).label == "Video encode")
        // Without rules, the built-in label is back.
        #expect(try group(for: vitest).kind == "vitest")
    }

    @Test("User rules never relabel root, other-user or protected processes")
    func userRulesSkipProtected() throws {
        let rules = WorkloadRule.parse("launchd = Mine\nsshd = Mine\nwindowserver = Mine").rules
        let root = SyntheticSnapshots.process(pid: 980, owner: .root, name: "sshd", executablePath: "/opt/local/sbin/sshd", arguments: nil)
        #expect(try group(for: root, rules: rules).kind != "custom")
        let windowServer = SyntheticSnapshots.process(pid: 981, owner: .otherUser, name: "WindowServer",
                                                      executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        #expect(try group(for: windowServer, rules: rules).kind != "custom")
    }

    // MARK: Process tree

    @Test("Descendants come depth-first with depth, bounded by depth and count, cycle-safe")
    func tree() {
        let processes = [
            SyntheticSnapshots.process(pid: 10, name: "zsh"),
            SyntheticSnapshots.process(pid: 11, parentPID: 10, name: "npm"),
            SyntheticSnapshots.process(pid: 12, parentPID: 11, name: "node"),
            SyntheticSnapshots.process(pid: 13, parentPID: 12, name: "esbuild"),
            SyntheticSnapshots.process(pid: 14, parentPID: 10, name: "claude"),
            SyntheticSnapshots.process(pid: 15, parentPID: 15, name: "self-parent"),
        ]
        let full = ProcessTree.descendants(of: 10, in: processes)
        #expect(full.nodes.map(\.process.pid) == [11, 12, 13, 14])
        #expect(full.nodes.map(\.depth) == [1, 2, 3, 1])
        #expect(!full.truncated)
        let shallow = ProcessTree.descendants(of: 10, in: processes, maxDepth: 2)
        #expect(shallow.nodes.map(\.process.pid) == [11, 12, 14] && shallow.truncated)
        let few = ProcessTree.descendants(of: 10, in: processes, maxCount: 2)
        #expect(few.nodes.count == 2 && few.truncated)
        #expect(ProcessTree.descendants(of: 15, in: processes).nodes.isEmpty)
    }
}
