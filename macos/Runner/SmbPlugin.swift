import Cocoa
import FlutterMacOS

/// macOS native SMB plugin using FileManager with smb:// URLs.
/// No mount_smbfs needed — macOS natively supports SMB via FileManager.
class SmbPlugin: NSObject, FlutterPlugin {
    private let httpServer = NativeSmbHttpServer()
    private let queue = DispatchQueue(label: "smb.plugin", qos: .userInitiated)

    // Session management
    private var sessions: [String: SmbSession] = [:]
    private let sessionLock = NSLock()

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.huangjx.media_play/smb",
            binaryMessenger: registrar.messenger
        )
        let instance = SmbPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "smbConnect":
            handleConnect(call, result: result)
        case "smbListFiles":
            handleListFiles(call, result: result)
        case "smbDisconnect":
            handleDisconnect(call, result: result)
        case "smbDeleteFile":
            handleDeleteFile(call, result: result)
        case "smbGetFileSize":
            handleGetFileSize(call, result: result)
        case "smbStartHttpServer":
            handleStartHttpServer(result: result)
        case "smbStopHttpServer":
            handleStopHttpServer(result: result)
        case "smbGetHttpUrl":
            handleGetHttpUrl(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - smbConnect

    private func handleConnect(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "SMB_CONNECT_ERROR", message: "Missing arguments", details: nil))
            return
        }
        let host = args["host"] as? String ?? ""
        let domain = args["domain"] as? String ?? ""
        let username = args["username"] as? String ?? ""
        let password = args["password"] as? String ?? ""

        queue.async { [weak self] in
            guard let self = self else { return }

            let sessionId = UUID().uuidString
            let session = SmbSession(
                id: sessionId,
                host: host,
                username: username,
                password: password
            )

            // Test connection by trying to list the server root
            let testUrl = self.buildSmbUrl(session: session, share: "", path: "")
            NSLog("[SMB Plugin] Connecting to: %@", testUrl.absoluteString)

            do {
                let fm = FileManager.default
                // Set up SMB credentials via URL
                _ = try fm.contentsOfDirectory(
                    at: testUrl,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                NSLog("[SMB Plugin] Connection test (expected for root): %@", error.localizedDescription)
                // Root listing might fail, that's OK — we just need the session
            }

            self.sessionLock.lock()
            self.sessions[sessionId] = session
            self.sessionLock.unlock()

            DispatchQueue.main.async { result(sessionId) }
        }
    }

    // MARK: - smbListFiles

    private func handleListFiles(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = args["sessionId"] as? String,
              let path = args["path"] as? String else {
            result(FlutterError(code: "SMB_LIST_ERROR", message: "Missing arguments", details: nil))
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let files = try self.listFiles(sessionId: sessionId, smbPath: path)
                DispatchQueue.main.async { result(files) }
            } catch {
                NSLog("[SMB Plugin] listFiles error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    result(FlutterError(code: "SMB_LIST_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    private func listFiles(sessionId: String, smbPath: String) throws -> [[String: Any]] {
        let session = try getSession(sessionId)
        let fm = FileManager.default

        // Parse SMB path: "shareName\folder\file" → share="shareName", subpath="folder/file"
        let normalized = smbPath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)

        NSLog("[SMB Plugin] listFiles called with path: '%@', components: %d", smbPath, components.count)

        if components.isEmpty {
            // Root path — list shares using smbutil
            NSLog("[SMB Plugin] Listing shares via smbutil...")
            let shares = try listShares(session: session)
            NSLog("[SMB Plugin] Found %d shares", shares.count)
            return shares
        }

        let shareName = String(components[0])
        let subPath = components.count > 1 ? String(components[1]) : ""

        // Build smb:// URL for the directory
        let dirUrl = buildSmbUrl(session: session, share: shareName, path: subPath)
        NSLog("[SMB Plugin] Listing: %@", dirUrl.absoluteString)

        let contents = try fm.contentsOfDirectory(
            at: dirUrl,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url -> [String: Any]? in
            let name = url.lastPathComponent
            if name == "." || name == ".." { return nil }

            let resourceValues = try? url.resourceValues(forKeys: [
                .fileSizeKey, .creationDateKey, .contentModificationDateKey,
                .isDirectoryKey
            ])

            let isDir = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize ?? 0
            let createDate = resourceValues?.creationDate?.timeIntervalSince1970 ?? 0
            let modDate = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0

            // Build SMB path (backslash separators like Android)
            let smbFilePath = subPath.isEmpty
                ? "\(shareName)\\\(name)"
                : "\(shareName)\\\(subPath)\\\(name)"

            return [
                "name": name,
                "path": smbFilePath,
                "size": size,
                "isDirectory": isDir,
                "createTime": Int64(createDate * 10000000),
                "lastModified": Int64(modDate * 10000000),
                "isReadonly": false,
            ] as [String: Any]
        }
    }

    // MARK: - smbDisconnect

    private func handleDisconnect(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = args["sessionId"] as? String else {
            result(FlutterError(code: "SMB_DISCONNECT_ERROR", message: "Missing sessionId", details: nil))
            return
        }

        sessionLock.lock()
        sessions.removeValue(forKey: sessionId)
        sessionLock.unlock()

        result(nil)
    }

    // MARK: - smbDeleteFile

    private func handleDeleteFile(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = args["sessionId"] as? String,
              let path = args["path"] as? String else {
            result(FlutterError(code: "SMB_DELETE_ERROR", message: "Missing arguments", details: nil))
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = try self.getSession(sessionId)
                let url = try self.smbPathToUrl(session: session, smbPath: path)
                try FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SMB_DELETE_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - smbGetFileSize

    private func handleGetFileSize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = args["sessionId"] as? String,
              let path = args["path"] as? String else {
            result(FlutterError(code: "SMB_SIZE_ERROR", message: "Missing arguments", details: nil))
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let session = try self.getSession(sessionId)
                let url = try self.smbPathToUrl(session: session, smbPath: path)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                DispatchQueue.main.async { result(size) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SMB_SIZE_ERROR", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: - HTTP Server

    private func handleStartHttpServer(result: @escaping FlutterResult) {
        do {
            let port = try httpServer.start()
            result(port)
        } catch {
            result(FlutterError(code: "SMB_HTTP_START_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func handleStopHttpServer(result: @escaping FlutterResult) {
        httpServer.stop()
        result(nil)
    }

    private func handleGetHttpUrl(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let sessionId = args["sessionId"] as? String,
              let path = args["path"] as? String,
              let fileName = args["fileName"] as? String else {
            result(FlutterError(code: "SMB_HTTP_URL_ERROR", message: "Missing arguments", details: nil))
            return
        }

        do {
            let session = try getSession(sessionId)
            let url = try smbPathToUrl(session: session, smbPath: path)
            // Store the SMB URL in the HTTP server for streaming
            let httpUrl = httpServer.buildSmbUrl(sessionId: sessionId, smbUrl: url.absoluteString, fileName: fileName)
            result(httpUrl)
        } catch {
            result(FlutterError(code: "SMB_HTTP_URL_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Helpers

    private func getSession(_ sessionId: String) throws -> SmbSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let session = sessions[sessionId] else {
            throw SmbError.sessionNotFound(sessionId)
        }
        return session
    }

    /// Build smb:// URL from session and path components.
    private func buildSmbUrl(session: SmbSession, share: String, path: String) -> URL {
        let user = session.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? ""
        let pass = session.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? ""
        let host = session.host

        var urlString = "smb://"
        if !user.isEmpty {
            urlString += user
            if !pass.isEmpty {
                urlString += ":\(pass)"
            }
            urlString += "@"
        }
        urlString += host

        if !share.isEmpty {
            urlString += "/\(share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share)"
        }

        if !path.isEmpty {
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            urlString += "/\(encodedPath)"
        }

        return URL(string: urlString) ?? URL(fileURLWithPath: "/")
    }

    /// Convert SMB path (shareName\folder\file) to smb:// URL.
    private func smbPathToUrl(session: SmbSession, smbPath: String) throws -> URL {
        let normalized = smbPath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)

        guard let shareName = components.first.map(String.init) else {
            throw SmbError.pathNotFound(smbPath)
        }

        let subPath = components.count > 1 ? String(components[1]) : ""
        return buildSmbUrl(session: session, share: shareName, path: subPath)
    }

    /// List available SMB shares using FileManager with smb:// URL.
    private func listShares(session: SmbSession) throws -> [[String: Any]] {
        let serverUrl = buildSmbUrl(session: session, share: "", path: "")
        NSLog("[SMB Plugin] Listing shares from: %@", serverUrl.absoluteString)

        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(
                at: serverUrl,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )

            var shares: [[String: Any]] = []
            for url in contents {
                let name = url.lastPathComponent
                if name.isEmpty || name == "." || name == ".." { continue }

                // Check if it's a directory (share)
                let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let isDir = resourceValues?.isDirectory ?? true

                shares.append([
                    "name": name,
                    "path": "\(name)\\",
                    "size": 0,
                    "isDirectory": isDir,
                    "createTime": Int64(0),
                    "lastModified": Int64(0),
                    "isReadonly": false,
                ] as [String: Any])
            }

            NSLog("[SMB Plugin] Found %d shares via FileManager", shares.count)
            return shares
        } catch {
            NSLog("[SMB Plugin] FileManager listShares failed: %@", error.localizedDescription)
            // Fallback to smbutil
            return try listSharesViaSmbutil(session: session)
        }
    }

    /// Fallback: list shares using smbutil with password via stdin.
    private func listSharesViaSmbutil(session: SmbSession) throws -> [[String: Any]] {
        // Write credentials file for smbutil
        let credFile = FileManager.default.temporaryDirectory.appendingPathComponent(".smb_\(session.id).plist")
        let credDict: [String: String] = [
            "smb_host": session.host,
            "smb_username": session.username,
            "smb_password": session.password,
        ]
        try (credDict as NSDictionary).write(to: credFile)
        defer { try? FileManager.default.removeItem(at: credFile) }

        // Use smbutil with the server URL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = ["view", "//\(session.username)@\(session.host)"]
        // Try passing password via environment with proper escaping
        var env = ProcessInfo.processInfo.environment
        env["PASSWD"] = session.password
        env["NTLM_USER_SESSION_KEY"] = ""
        process.environment = env

        // Use a pipe for stdin to provide password if prompted
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Write password to stdin in case smbutil prompts
        stdinPipe.fileHandleForWriting.write(session.password.data(using: .utf8) ?? Data())
        stdinPipe.fileHandleForWriting.write("\n".data(using: .utf8)!)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        NSLog("[SMB Plugin] smbutil view exit: %d", process.terminationStatus)
        NSLog("[SMB Plugin] smbutil view output: %@", output)
        if !errorOutput.isEmpty {
            NSLog("[SMB Plugin] smbutil view stderr: %@", errorOutput)
        }

        var shares: [[String: Any]] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("Share") || trimmed.hasPrefix("---") || trimmed.hasPrefix("Server") { continue }

            let parts = trimmed.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, parts[1] == "Disk" else { continue }

            shares.append([
                "name": parts[0],
                "path": "\(parts[0])\\",
                "size": 0,
                "isDirectory": true,
                "createTime": Int64(0),
                "lastModified": Int64(0),
                "isReadonly": false,
            ] as [String: Any])
        }

        return shares
    }
}

// MARK: - Supporting Types

private class SmbSession {
    let id: String
    let host: String
    let username: String
    let password: String

    init(id: String, host: String, username: String, password: String) {
        self.id = id
        self.host = host
        self.username = username
        self.password = password
    }
}

enum SmbError: Error, LocalizedError {
    case sessionNotFound(String)
    case pathNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id): return "SMB session not found: \(id)"
        case .pathNotFound(let path): return "Path not found: \(path)"
        }
    }
}
