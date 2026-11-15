import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String) { self.status = status; self.output = output }
    public var succeeded: Bool { status == 0 }
}

/// The updater's only way to run programs, so tests can assert the exact sequence.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], cwd: String?) async -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: String, _ arguments: [String]) async -> CommandResult { await run(executable, arguments, cwd: nil) }
}

/// launchd gives jobs a bare PATH; the build script calls swift, git, plutil and codesign by name.
public struct ProcessRunner: CommandRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String], cwd: String?) async -> CommandResult {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { return CommandResult(status: -1, output: "") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
