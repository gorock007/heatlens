import Foundation

/// Docker Engine answers for the container-stop tests, shaped like Docker Desktop 28.5.1
/// (API 1.51). IDs, names, labels and paths are synthetic.
enum ContainerStopFixtures {
    static let id = String(repeating: "2b9aeb6c80e3", count: 5) + "d19e"
    static let otherID = String(repeating: "a1b2c3d4e5f6", count: 5) + "0123"
    static let name = "demo-db-1"
    static let image = "postgres:17"
    /// The list's `Created` (Unix seconds) and the same instant as inspect writes it.
    static let createdSeconds: Int64 = 1_792_760_413
    static let createdRFC3339 = "2026-10-23T13:00:13.512345678Z"

    static let version = #"{"Version":"28.5.1","ApiVersion":"1.51","MinAPIVersion":"1.24","Os":"linux"}"#

    /// `stopTimeout: nil` writes `null`, as the Engine does for a container without one.
    static func inspect(id: String = id, name: String = "/" + name, created: String = createdRFC3339,
                        status: String = "running", stopTimeout: Int? = nil, stopSignal: String? = nil,
                        labels: [String: String] = composeLabels, restartPolicy: String = "no") -> String {
        let labelJSON = labels.sorted { $0.key < $1.key }.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
        let timeout = stopTimeout.map(String.init) ?? "null"
        let signal = stopSignal.map { #""StopSignal":"\#($0)","# } ?? ""
        return """
        {"Id":"\(id)","Created":"\(created)","Path":"docker-entrypoint.sh","Args":["postgres"],
         "State":{"Status":"\(status)","Running":\(status == "running"),"Paused":false,"Restarting":false,"OOMKilled":false,
                  "Dead":false,"Pid":4242,"ExitCode":0,"Error":"","StartedAt":"2026-10-24T08:00:00.000000001Z",
                  "FinishedAt":"0001-01-01T00:00:00Z"},
         "Image":"sha256:\(String(repeating: "0", count: 64))","Name":"\(name)","RestartCount":0,
         "HostConfig":{"Binds":["/Users/someone/Developer/demo/data:/var/lib/postgresql/data"],
                       "RestartPolicy":{"Name":"\(restartPolicy)","MaximumRetryCount":0}},
         "Config":{"Hostname":"2b9aeb6c80e3","User":"","Env":["POSTGRES_PASSWORD=placeholder"],"Image":"\(image)",
                   \(signal)"StopTimeout":\(timeout),"Labels":{\(labelJSON)}}}
        """
    }

    static let composeLabels = [
        "com.docker.compose.project": "demo",
        "com.docker.compose.service": "db",
        "com.docker.compose.project.working_dir": "/Users/someone/Developer/demo",
    ]

    static func list(state: String) -> String {
        #"[{"Id":"\#(id)","Names":["/\#(name)"],"Image":"\#(image)","State":"\#(state)","Status":"","Created":\#(createdSeconds),"Labels":{}}]"#
    }

    static func error(_ message: String) -> String {
        #"{"message":"\#(message)"}"#
    }
}
