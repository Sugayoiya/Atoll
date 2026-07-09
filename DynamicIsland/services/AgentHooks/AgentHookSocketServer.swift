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
import Defaults

/// Single source of truth for the hook timeout chain, derived from the
/// user-configurable UI prompt budget (`Defaults[.agentPromptTimeoutSeconds]`).
///
/// Chain invariant (MUST hold): UI < server (UI+5) < script recv (UI+10)
/// < host hook timeout (UI+20). Every derived value reads Defaults at call
/// time; changing the setting re-runs `installIfNeeded()` (content diffing
/// rewrites the scripts and config timeouts automatically).
enum AgentPromptTimeout {
    static let range: ClosedRange<Double> = 10...300

    /// UI budget: how long a pending prompt waits in the Agents tab.
    static var uiSeconds: TimeInterval {
        min(max(Defaults[.agentPromptTimeoutSeconds], range.lowerBound), range.upperBound)
    }

    /// Socket server reply window (semaphore bound).
    static var serverSeconds: TimeInterval { uiSeconds + 5 }

    /// `sock.settimeout(...)` embedded in the generated hook scripts.
    static var scriptRecvSeconds: Int { Int(uiSeconds) + 10 }

    /// `timeout` written into Claude's settings.json / Cursor's hooks.json.
    static var hostHookSeconds: Int { Int(uiSeconds) + 20 }
}

/// Minimal Unix domain socket server that receives `AgentHookEnvelope` JSON
/// from provider hook scripts at `/tmp/atoll-agent.sock`.
///
/// The channel is bidirectional: after decoding an envelope, the handler may
/// return response bytes (a provider-specific decision JSON) that are written
/// back on the same client connection before it is closed. Returning `nil`
/// closes the connection without a reply, preserving the fire-and-forget flow.
///
/// Owns its synchronization via dedicated dispatch queues.
final class AgentHookSocketServer: @unchecked Sendable {
    /// Handles a decoded hook envelope and optionally produces reply bytes to
    /// send back to the hook script (which prints them to stdout for the agent).
    typealias EventHandler = @Sendable (AgentHookEnvelope) async -> Data?

    static let shared = AgentHookSocketServer()

    static let socketPath = "/tmp/atoll-agent.sock"

    /// Upper bound for producing a reply. The hook script waits UI+10s for a
    /// response; if the handler takes longer we close the connection with no
    /// reply so the script (and the agent's normal permission flow) proceeds.
    /// Chain invariant: UI < server (UI+5) < script recv (UI+10) < host hook timeout (UI+20).
    private static var responseTimeout: TimeInterval { AgentPromptTimeout.serverSeconds }

    private let socketPath = AgentHookSocketServer.socketPath
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: EventHandler?
    private let serverQueue = DispatchQueue(label: "com.ebullioscopic.Atoll.agent.socket", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.ebullioscopic.Atoll.agent.socket.client", qos: .userInitiated, attributes: .concurrent)

    private init() {}

    func start(onEvent: @escaping EventHandler) {
        serverQueue.async { [weak self] in
            self?.startServer(onEvent: onEvent)
        }
    }

    func stop() {
        serverQueue.async { [weak self] in
            self?.stopServer()
        }
    }

    private func startServer(onEvent: @escaping EventHandler) {
        guard serverSocket < 0 else { return }

        // Remove any stale socket file from a previous run.
        if FileManager.default.fileExists(atPath: socketPath) {
            unlink(socketPath)
        }

        eventHandler = onEvent

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Logger.log("Agent hook socket creation failed: \(errno)", category: .error)
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
            Logger.log("Agent hook socket bind failed: \(errno)", category: .error)
            close(serverSocket)
            serverSocket = -1
            return
        }

        _ = chmod(socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            Logger.log("Agent hook socket listen failed: \(errno)", category: .error)
            close(serverSocket)
            serverSocket = -1
            return
        }

        Logger.log("Agent hook socket listening at \(socketPath)", category: .network)

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
                Logger.log("Agent hook socket accept failed: \(acceptError)", category: .error)
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

    private static func handleClient(_ clientSocket: Int32, eventHandler: EventHandler?) {
        defer { close(clientSocket) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        // The hook script half-closes its write side after sending, so this
        // loop reads until EOF while the connection itself stays open for a reply.
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
              let envelope = try? JSONDecoder().decode(AgentHookEnvelope.self, from: allData),
              let eventHandler else {
            return
        }

        // Bridge the async handler onto this blocking client-queue thread,
        // bounded so a stalled handler never leaves the hook script hanging.
        let response = awaitResponse(for: envelope, eventHandler: eventHandler)

        if let response, !response.isEmpty {
            writeAll(response, to: clientSocket)
        }
    }

    private static func awaitResponse(for envelope: AgentHookEnvelope, eventHandler: @escaping EventHandler) -> Data? {
        let box = ResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let result = await eventHandler(envelope)
            box.store(result)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + responseTimeout) == .success else {
            Logger.log("Agent hook handler timed out; closing connection with no decision", category: .warning)
            return nil
        }
        return box.take()
    }

    private static func writeAll(_ data: Data, to clientSocket: Int32) {
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = write(clientSocket, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                    continue
                }
                if errno == EINTR { continue }
                Logger.log("Agent hook socket reply write failed: \(errno)", category: .error)
                return
            }
        }
    }

    /// Thread-safe single-value box used to hand the handler result from the
    /// async Task back to the blocking client-queue thread.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func store(_ data: Data?) {
            lock.lock()
            value = data
            lock.unlock()
        }

        func take() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
