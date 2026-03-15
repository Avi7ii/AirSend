import Foundation
import Darwin

final class PlainHTTPCompatServer: @unchecked Sendable {
    typealias NewConnectionHandler = @Sendable (PlainHTTPCompatConnection) -> Void

    private let port: UInt16
    private let listenerQueue = DispatchQueue(label: "com.localsend.server.compat-listener", qos: .userInteractive)
    private let activeSocketsQueue = DispatchQueue(label: "com.localsend.server.compat-active")

    private var listeningSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var activeSockets: Set<Int32> = []

    var onNewConnection: NewConnectionHandler?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        guard listeningSocket == -1 else { return }

        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw Self.makePOSIXError(function: "socket")
        }

        do {
            try Self.configureListeningSocket(socketFD)

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0))

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard bindResult == 0 else {
                throw Self.makePOSIXError(function: "bind")
            }

            guard Darwin.listen(socketFD, SOMAXCONN) == 0 else {
                throw Self.makePOSIXError(function: "listen")
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: listenerQueue)
            source.setEventHandler { [weak self] in
                self?.acceptPendingConnections()
            }
            source.setCancelHandler {
                Darwin.close(socketFD)
            }
            source.resume()

            listeningSocket = socketFD
            acceptSource = source
            logTransfer("🌐 Plain HTTP compatibility server listening on port \(port) via BSD sockets.")
        } catch {
            Darwin.close(socketFD)
            throw error
        }
    }

    func stop() {
        let source = acceptSource
        acceptSource = nil

        if listeningSocket != -1 {
            Darwin.shutdown(listeningSocket, SHUT_RDWR)
            source?.cancel()
            listeningSocket = -1
        } else {
            source?.cancel()
        }

        let sockets = activeSocketsQueue.sync { () -> [Int32] in
            let copy = Array(activeSockets)
            activeSockets.removeAll()
            return copy
        }

        for socketFD in sockets {
            Darwin.shutdown(socketFD, SHUT_RDWR)
            Darwin.close(socketFD)
        }
    }

    private func acceptPendingConnections() {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.stride)

            let clientSocket = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listeningSocket, $0, &length)
                }
            }

            if clientSocket == -1 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                if errno != EBADF {
                    logTransfer("❌ Plain HTTP compatibility server accept failed: \(Self.makePOSIXError(function: "accept").localizedDescription)")
                }
                break
            }

            do {
                try Self.configureAcceptedSocket(clientSocket)
            } catch {
                logTransfer("❌ Failed to configure accepted compatibility socket: \(error.localizedDescription)")
                Darwin.close(clientSocket)
                continue
            }

            _ = activeSocketsQueue.sync {
                activeSockets.insert(clientSocket)
            }

            let connection = PlainHTTPCompatConnection(
                socket: clientSocket,
                remoteAddress: storage,
                onClose: { [weak self] closedSocket in
                    _ = self?.activeSocketsQueue.sync {
                        self?.activeSockets.remove(closedSocket)
                    }
                }
            )

            onNewConnection?(connection)
        }
    }

    private static func configureListeningSocket(_ socketFD: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_REUSEADDR)")
        }

        #if os(macOS)
        guard setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_NOSIGPIPE)")
        }
        #endif

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags != -1 else {
            throw makePOSIXError(function: "fcntl(F_GETFL)")
        }
        guard fcntl(socketFD, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
            throw makePOSIXError(function: "fcntl(F_SETFL)")
        }
    }

    private static func configureAcceptedSocket(_ socketFD: Int32) throws {
        var yes: Int32 = 1
        guard setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw makePOSIXError(function: "setsockopt(TCP_NODELAY)")
        }
        guard setsockopt(socketFD, SOL_SOCKET, SO_KEEPALIVE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_KEEPALIVE)")
        }

        #if os(macOS)
        guard setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_NOSIGPIPE)")
        }
        #endif

        let currentFlags = fcntl(socketFD, F_GETFL, 0)
        guard currentFlags != -1 else {
            throw makePOSIXError(function: "fcntl(F_GETFL)")
        }
        guard fcntl(socketFD, F_SETFL, currentFlags & ~O_NONBLOCK) != -1 else {
            throw makePOSIXError(function: "fcntl(F_SETFL)")
        }

        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        guard setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.stride)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_RCVTIMEO)")
        }
        guard setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.stride)) == 0 else {
            throw makePOSIXError(function: "setsockopt(SO_SNDTIMEO)")
        }
    }

    fileprivate static func makePOSIXError(function: String, errnoCode: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errnoCode),
            userInfo: [NSLocalizedDescriptionKey: "\(function) failed: \(String(cString: strerror(errnoCode)))"]
        )
    }
}

final class PlainHTTPCompatConnection: @unchecked Sendable {
    let socket: Int32
    let remoteIP: String
    let remoteDescription: String

    private let closeLock = NSLock()
    private var isClosed = false
    private let onClose: @Sendable (Int32) -> Void

    init(socket: Int32, remoteAddress: sockaddr_storage, onClose: @escaping @Sendable (Int32) -> Void) {
        self.socket = socket
        self.onClose = onClose

        let resolved = Self.describe(remoteAddress: remoteAddress)
        self.remoteIP = resolved.host
        self.remoteDescription = resolved.description
    }

    func receive(maxLength: Int = 65536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxLength)

        while true {
            let readCount = Darwin.recv(socket, &buffer, maxLength, 0)
            if readCount > 0 {
                return Data(buffer.prefix(readCount))
            }
            if readCount == 0 {
                return Data()
            }
            if errno == EINTR {
                continue
            }
            throw PlainHTTPCompatServer.makePOSIXError(function: "recv")
        }
    }

    func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                let remaining = rawBuffer.count - bytesSent
                let result = Darwin.send(socket, baseAddress.advanced(by: bytesSent), remaining, 0)

                if result > 0 {
                    bytesSent += result
                    continue
                }
                if result == -1 && errno == EINTR {
                    continue
                }
                throw PlainHTTPCompatServer.makePOSIXError(function: "send")
            }
        }
    }

    func close() {
        closeLock.lock()
        if isClosed {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()

        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        onClose(socket)
    }

    private static func describe(remoteAddress: sockaddr_storage) -> (host: String, description: String) {
        var storage = remoteAddress
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serviceBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let addressLength = socklen_t(storage.ss_len)

        let result = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0,
                    addressLength,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    &serviceBuffer,
                    socklen_t(serviceBuffer.count),
                    NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }

        guard result == 0 else {
            return ("unknown", "unknown")
        }

        let host = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let service = String(decoding: serviceBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (host, "\(host):\(service)")
    }
}
