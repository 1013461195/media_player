import Foundation

/// Lightweight HTTP server for streaming SMB files over localhost.
/// Supports Range requests for random-access seeking during video playback.
/// Can read from both local paths and smb:// URLs.
class NativeSmbHttpServer {
    private var serverFd: Int32 = -1
    private var port: UInt16 = 0
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "smb.http.server", attributes: .concurrent)

    // LRU cache of open file handles (for local files)
    private var fileHandles: [String: FileHandle] = [:]
    private var accessOrder: [String] = []
    private let maxCachedHandles = 4
    private let handleLock = NSLock()

    // SMB URL storage: key -> smb:// URL
    private var smbUrls: [String: URL] = [:]
    private let urlLock = NSLock()

    // MARK: - Lifecycle

    func start() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SmbHttpError.socketCreateFailed }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SmbHttpError.bindFailed
        }

        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addrLen) }
        }
        self.port = UInt16(bigEndian: addr.sin_port)

        guard listen(fd, 128) == 0 else {
            close(fd)
            throw SmbHttpError.listenFailed
        }

        self.serverFd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.serverFd >= 0 {
                close(self.serverFd)
                self.serverFd = -1
            }
        }
        source.resume()
        self.acceptSource = source

        return Int(self.port)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        handleLock.lock()
        for (_, fh) in fileHandles { fh.closeFile() }
        fileHandles.removeAll()
        accessOrder.removeAll()
        handleLock.unlock()
        urlLock.lock()
        smbUrls.removeAll()
        urlLock.unlock()
    }

    /// Build HTTP URL for a local file path.
    func buildUrl(sessionId: String, path: String, fileName: String) -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName
        return "http://127.0.0.1:\(port)/video?s=\(sessionId)&p=\(encodedPath)&n=\(encodedName)"
    }

    /// Build HTTP URL that streams from an smb:// URL.
    func buildSmbUrl(sessionId: String, smbUrl: String, fileName: String) -> String {
        let key = "\(sessionId)|\(fileName)"
        urlLock.lock()
        smbUrls[key] = URL(string: smbUrl)
        urlLock.unlock()
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName
        return "http://127.0.0.1:\(port)/video?s=\(sessionId)&n=\(encodedName)&smb=1"
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        guard serverFd >= 0 else { return }
        for _ in 0..<16 {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverFd, $0, &addrLen) }
            }
            guard clientFd >= 0 else { break }
            queue.async { [weak self] in
                self?.handleClient(clientFd)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let pathWithQuery = String(parts[1])

        guard let url = URL(string: "http://127.0.0.1\(pathWithQuery)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            sendError(fd, status: 400, message: "Bad Request")
            return
        }

        let queryItems = components.queryItems ?? []
        func queryParam(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        guard let sessionId = queryParam("s") else {
            sendError(fd, status: 400, message: "Missing session")
            return
        }

        let isSmb = queryParam("smb") == "1"
        let fileName = queryParam("n")?.removingPercentEncoding ?? ""

        // Parse Range header
        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }

        if isSmb {
            // Stream from smb:// URL
            let key = "\(sessionId)|\(fileName)"
            urlLock.lock()
            let smbUrl = smbUrls[key]
            urlLock.unlock()

            guard let smbUrl = smbUrl else {
                sendError(fd, status: 404, message: "SMB URL not found")
                return
            }

            streamFromSmb(fd: fd, smbUrl: smbUrl, rangeHeader: rangeHeader)
        } else {
            // Stream from local file path
            guard let encodedPath = queryParam("p"),
                  let filePath = encodedPath.removingPercentEncoding else {
                sendError(fd, status: 400, message: "Missing path")
                return
            }
            streamFromLocalFile(fd: fd, filePath: filePath, sessionId: sessionId, rangeHeader: rangeHeader)
        }
    }

    // MARK: - Stream from SMB URL

    private func streamFromSmb(fd: Int32, smbUrl: URL, rangeHeader: String?) {
        // Get file size via HEAD request
        var headRequest = URLRequest(url: smbUrl)
        headRequest.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        var fileSize: Int64 = 0

        URLSession.shared.dataTask(with: headRequest) { _, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                fileSize = Int64(httpResponse.expectedContentLength)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)

        if fileSize <= 0 {
            // Fallback: try to get size from FileManager
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: smbUrl.path)
                fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                sendError(fd, status: 404, message: "Cannot determine file size")
                return
            }
            if fileSize <= 0 {
                sendError(fd, status: 404, message: "Cannot determine file size")
                return
            }
        }

        // Determine range
        let start: Int64
        let end: Int64
        let statusCode: Int
        let contentLength: Int64

        if let rangeHeader = rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let rangeSpec = String(rangeHeader.dropFirst(6))
            let rangeParts = rangeSpec.split(separator: "-")
            if rangeParts.count == 2 {
                if rangeParts[0].isEmpty {
                    let suffix = Int64(rangeParts[1]) ?? 0
                    start = max(0, fileSize - suffix)
                    end = fileSize - 1
                } else if rangeParts[1].isEmpty {
                    start = Int64(rangeParts[0]) ?? 0
                    end = fileSize - 1
                } else {
                    start = Int64(rangeParts[0]) ?? 0
                    end = min(Int64(rangeParts[1]) ?? 0, fileSize - 1)
                }
                statusCode = 206
                contentLength = end - start + 1
            } else {
                start = 0; end = fileSize - 1; statusCode = 200; contentLength = fileSize
            }
        } else {
            start = 0; end = fileSize - 1; statusCode = 200; contentLength = fileSize
        }

        // Send headers
        let contentType = guessContentType(smbUrl.lastPathComponent)
        var header = "HTTP/1.1 \(statusCode) \(statusCode == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if statusCode == 206 {
            header += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        guard let headerData = header.data(using: .utf8) else { return }
        headerData.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        // Download the range using URLSession
        var request = URLRequest(url: smbUrl)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")

        let downloadSemaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { downloadSemaphore.signal() }
            guard let data = data, !data.isEmpty else { return }

            // Send data in chunks
            let chunkSize = 1024 * 1024
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let chunk = data[offset..<end]
                chunk.withUnsafeBytes { ptr in
                    _ = send(fd, ptr.baseAddress!, ptr.count, 0)
                }
                offset = end
            }
        }.resume()

        _ = downloadSemaphore.wait(timeout: .now() + 300)
    }

    // MARK: - Stream from Local File

    private func streamFromLocalFile(fd: Int32, filePath: String, sessionId: String, rangeHeader: String?) {
        guard let fh = cachedFileHandle(sessionId: sessionId, path: filePath) else {
            sendError(fd, status: 404, message: "File not found")
            return
        }

        let fileSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
            fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            sendError(fd, status: 404, message: "File not found")
            return
        }

        guard fileSize > 0 else {
            sendError(fd, status: 404, message: "Empty file")
            return
        }

        let start: Int64
        let end: Int64
        let statusCode: Int
        let contentLength: Int64

        if let rangeHeader = rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let rangeSpec = String(rangeHeader.dropFirst(6))
            let rangeParts = rangeSpec.split(separator: "-")
            if rangeParts.count == 2 {
                if rangeParts[0].isEmpty {
                    let suffix = Int64(rangeParts[1]) ?? 0
                    start = max(0, fileSize - suffix)
                    end = fileSize - 1
                } else if rangeParts[1].isEmpty {
                    start = Int64(rangeParts[0]) ?? 0
                    end = fileSize - 1
                } else {
                    start = Int64(rangeParts[0]) ?? 0
                    end = min(Int64(rangeParts[1]) ?? 0, fileSize - 1)
                }
                statusCode = 206
                contentLength = end - start + 1
            } else {
                start = 0; end = fileSize - 1; statusCode = 200; contentLength = fileSize
            }
        } else {
            start = 0; end = fileSize - 1; statusCode = 200; contentLength = fileSize
        }

        let contentType = guessContentType(filePath)
        var header = "HTTP/1.1 \(statusCode) \(statusCode == 206 ? "Partial Content" : "OK")\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if statusCode == 206 {
            header += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        guard let headerData = header.data(using: .utf8) else { return }
        headerData.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        let chunkSize = 1024 * 1024
        var offset = start
        while offset <= end {
            let remaining = end - offset + 1
            let toRead = min(Int64(chunkSize), remaining)
            fh.seek(toFileOffset: UInt64(offset))
            let data = fh.readData(ofLength: Int(toRead))
            guard !data.isEmpty else { break }
            let sent = data.withUnsafeBytes { ptr in
                send(fd, ptr.baseAddress!, ptr.count, 0)
            }
            if sent <= 0 { break }
            offset += Int64(data.count)
        }
    }

    // MARK: - File Handle Cache

    private func cachedFileHandle(sessionId: String, path: String) -> FileHandle? {
        let key = "\(sessionId)|\(path)"
        handleLock.lock()
        defer { handleLock.unlock() }

        if let existing = fileHandles[key] {
            accessOrder.removeAll { $0 == key }
            accessOrder.append(key)
            return existing
        }

        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }

        while fileHandles.count >= maxCachedHandles, let oldest = accessOrder.first {
            fileHandles[oldest]?.closeFile()
            fileHandles.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        fileHandles[key] = fh
        accessOrder.append(key)
        return fh
    }

    // MARK: - Helpers

    private func sendError(_ fd: Int32, status: Int, message: String) {
        let body = "<html><body><h1>\(status) \(message)</h1></body></html>"
        let header = "HTTP/1.1 \(status) \(message)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        if let data = (header + body).data(using: .utf8) {
            data.withUnsafeBytes { ptr in
                _ = send(fd, ptr.baseAddress!, ptr.count, 0)
            }
        }
    }

    private func guessContentType(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "wmv": return "video/x-ms-wmv"
        case "flv": return "video/x-flv"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

enum SmbHttpError: Error {
    case socketCreateFailed
    case bindFailed
    case listenFailed
}
