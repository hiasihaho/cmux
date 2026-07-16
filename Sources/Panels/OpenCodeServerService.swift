import Foundation

actor OpenCodeServerService: OpenCodeServerServing {
    private struct PendingConnection {
        let continuation: CheckedContinuation<OpenCodeServerConnection, Error>
    }

    private var process: Process?
    private var connection: OpenCodeServerConnection?
    private var pendingConnections: [PendingConnection] = []
    private var stdoutReadTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    private var leaseCount = 0

    func acquireConnection(plan: AgentSessionLaunchPlan) async throws -> OpenCodeServerConnection {
        guard plan.provider == .opencode else {
            throw AgentSessionBridgeError.invalidRequest
        }
        if let connection {
            leaseCount += 1
            return connection
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections.append(PendingConnection(continuation: continuation))
            guard process == nil else { return }
            do {
                try launch(plan: plan)
            } catch {
                failPendingConnections(error)
            }
        }
    }

    func releaseConnection() {
        guard leaseCount > 0 else { return }
        leaseCount -= 1
        guard leaseCount == 0, pendingConnections.isEmpty else { return }
        stopServer()
    }

    nonisolated static func serverURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
    }

    private func launch(plan: AgentSessionLaunchPlan) throws {
        let launchEnvironment = plan.environment(overridingWorkingDirectory: nil)
        guard OpenCodeServerAuth(environment: launchEnvironment) != nil else {
            throw AgentSessionBridgeError.providerNotReady(plan.provider.displayName)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = launchEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.serverExited(
                    processIdentifier: process.processIdentifier,
                    status: process.terminationStatus
                )
            }
        }

        self.process = process
        stdoutReadTask = makeReadTask(stdout.fileHandleForReading)
        stderrReadTask = makeReadTask(stderr.fileHandleForReading)

        do {
            try process.run()
        } catch {
            stopServer()
            throw error
        }
    }

    private func makeReadTask(_ fileHandle: FileHandle) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [weak self] in
            var buffer = AgentSessionOutputLineBuffer()
            while !Task.isCancelled {
                let data: Data
                do {
                    data = try fileHandle.read(upToCount: 64 * 1024) ?? Data()
                } catch {
                    data = Data()
                }
                for line in buffer.append(data) {
                    await self?.consumeOutputLine(line)
                }
                if data.isEmpty {
                    for line in buffer.flush() {
                        await self?.consumeOutputLine(line)
                    }
                    return
                }
            }
        }
    }

    private func consumeOutputLine(_ text: String) {
        guard connection == nil,
              let process,
              let baseURL = Self.serverURL(from: text),
              let auth = OpenCodeServerAuth(environment: process.environment ?? [:]) else {
            return
        }
        let connection = OpenCodeServerConnection(
            baseURL: baseURL,
            authorizationHeader: auth.authorizationHeader,
            processIdentifier: process.processIdentifier
        )
        self.connection = connection
        let pending = pendingConnections
        pendingConnections.removeAll(keepingCapacity: false)
        leaseCount += pending.count
        for waiter in pending {
            waiter.continuation.resume(returning: connection)
        }
    }

    private func serverExited(processIdentifier: Int32, status: Int32) {
        guard process?.processIdentifier == processIdentifier else { return }
        let error = AgentSessionBridgeError.providerNotReady(
            "\(AgentSessionProviderID.opencode.displayName) (exit \(status))"
        )
        failPendingConnections(error)
        clearServerState()
    }

    private func failPendingConnections(_ error: Error) {
        let pending = pendingConnections
        pendingConnections.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func stopServer() {
        if let process, process.isRunning {
            process.terminate()
        }
        clearServerState()
    }

    private func clearServerState() {
        stdoutReadTask?.cancel()
        stdoutReadTask = nil
        stderrReadTask?.cancel()
        stderrReadTask = nil
        process = nil
        connection = nil
        leaseCount = 0
    }
}
