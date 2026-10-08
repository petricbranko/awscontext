import Foundation

public enum AWSCLIError: LocalizedError, Equatable {
    case notInstalled
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The AWS CLI was not found. Install it with “brew install awscli” or from https://aws.amazon.com/cli/."
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Runs the `aws` command line tool. Apps launched from Finder don't inherit the
/// shell's PATH, so common install locations are searched explicitly.
public final class AWSCLI {
    public let paths: AWSPaths
    public let executable: URL?

    private static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public init(paths: AWSPaths, executable: URL? = AWSCLI.locate()) {
        self.paths = paths
        self.executable = executable
    }

    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = searchPath.map { "\($0)/aws" } + ["\(home)/.local/bin/aws", "\(home)/bin/aws"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Runs `aws <arguments>` and returns stdout. `onStart` receives the process so callers can cancel it.
    @discardableResult
    public func run(_ arguments: [String], onStart: ((Process) -> Void)? = nil) async throws -> String {
        guard let executable else { throw AWSCLIError.notInstalled }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (Self.searchPath + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["AWS_SHARED_CREDENTIALS_FILE"] = paths.credentials.path
        environment["AWS_CONFIG_FILE"] = paths.config.path
        environment["AWS_PAGER"] = ""
        // The selected profile must win over anything inherited from a parent shell.
        for variable in ["AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"] {
            environment.removeValue(forKey: variable)
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            // Drain both pipes concurrently so a chatty process can't block on a full buffer.
            let group = DispatchGroup()
            let output = OutputBuffer()
            let errorOutput = OutputBuffer()
            for (pipe, buffer) in [(stdout, output), (stderr, errorOutput)] {
                group.enter()
                DispatchQueue.global().async {
                    buffer.data = pipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
            }
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    let text = String(decoding: output.data, as: UTF8.self)
                    if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: AWSCLIError.cancelled)
                    } else if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        let message = String(decoding: errorOutput.data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: AWSCLIError.failed(message.isEmpty ? text : message))
                    }
                }
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Written once by a reader thread, read after the DispatchGroup completes.
private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}
