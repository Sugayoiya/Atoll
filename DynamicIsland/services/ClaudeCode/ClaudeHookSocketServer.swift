/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// A raw hook event payload sent by the Claude Code hook script.
struct ClaudeHookEvent: Decodable, Sendable {
    let provider: String?
    let sessionId: String
    let cwd: String?
    let event: String
    let tool: String?
    let userPrompt: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case sessionId = "session_id"
        case cwd, event, tool
        case userPrompt = "user_prompt"
    }
}

/// Minimal Unix domain socket server that receives JSON events from the
/// Claude Code hook script at `/tmp/atoll-claude.sock`.
/// Owns its synchronization via dedicated dispatch queues.
final class ClaudeHookSocketServer: @unchecked Sendable {
    static let shared = ClaudeHookSocketServer()

    private let socketPath = ClaudeHookScript.socketPath
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: (@Sendable (ClaudeHookEvent) -> Void)?
    private let serverQueue = DispatchQueue(label: "com.ebullioscopic.Atoll.claude.socket", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ebullioscopic.Atoll.claude.socket.client", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    func start(onEvent: @escaping @Sendable (ClaudeHookEvent) -> Void) {
        serverQueue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    func stop() {
        serverQueue.async { [weak self] in
            self?.stopServer()
        }
    }

    private func startServer(onEvent: @escaping @Sendable (ClaudeHookEvent) -> Void) {
        guard serverSocket < 0 else { return }

        // Remove any stale socket file from a previous run.
        if FileManager.default.fileExists(atPath: socketPath) {
            unlink(socketPath)
        }

        eventHandler = onEvent

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Logger.log("Claude hook socket creation failed: \(errno)", category: .error)
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Logger.log("Claude hook socket bind failed: \(errno)", category: .error)
            close(serverSocket)
            serverSocket = -1
            return
        }

        _ = chmod(socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            Logger.log("Claude hook socket listen failed: \(errno)", category: .error)
            close(serverSocket)
            serverSocket = -1
            return
        }

        Logger.log("Claude hook socket listening at \(socketPath)", category: .network)

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: serverQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    private func stopServer() {
        if let acceptSource {
            acceptSource.cancel()
            self.acceptSource = nil
        } else if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        unlink(socketPath)
    }

    private func acceptConnections() {
        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                let acceptError = errno
                if acceptError == EINTR { continue }
                if acceptError == EAGAIN || acceptError == EWOULDBLOCK { return }
                Logger.log("Claude hook socket accept failed: \(acceptError)", category: .error)
                return
            }

            // Blocking reads on the client queue; suppress SIGPIPE.
            let clientFlags = fcntl(clientSocket, F_GETFL)
            if clientFlags >= 0 {
                _ = fcntl(clientSocket, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            var suppressSigPipe: Int32 = 1
            _ = withUnsafePointer(to: &suppressSigPipe) { pointer in
                setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
            }

            let handler = eventHandler
            clientQueue.async {
                Self.handleClient(clientSocket, eventHandler: handler)
            }
        }
    }

    private static func handleClient(_ clientSocket: Int32, eventHandler: (@Sendable (ClaudeHookEvent) -> Void)?) {
        defer { close(clientSocket) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                allData.append(contentsOf: buffer[0..<bytesRead])
                continue
            }
            if bytesRead == 0 { break }
            if errno == EINTR { continue }
            return
        }

        guard !allData.isEmpty,
              let event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: allData) else {
            return
        }

        eventHandler?(event)
    }
}
