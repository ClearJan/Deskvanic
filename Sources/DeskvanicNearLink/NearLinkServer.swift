import CryptoKit
import Foundation
import Network
import DeskvanicCore

/// NearLink 最小 HTTP/1.1 服务器（Network.framework）。
///
/// 安全模型（如实声明）：
/// - 局域网 HTTP + 访问令牌；**不是 TLS，不是端到端加密**，UI 与文档不这样宣传。
/// - 所有路由（除 403 提示页）必须携带有效令牌；令牌随机 128bit、会话可过期重置。
/// - 上传大小上限保护；路径参数不允许穿越。
public final class NearLinkServer: @unchecked Sendable {

    // MARK: - 配置与会话

    public struct Session: Sendable {
        public let token: String
        public let createdAt: Date
        public var expiresAt: Date

        public func isValid(at now: Date = Date()) -> Bool {
            now < expiresAt
        }
    }

    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var _session: Session?
    public private(set) var port: UInt16 = 0

    /// 上传大小上限（默认 500MB）。
    public var maxBodyBytes: Int = 500 * 1024 * 1024
    /// 同时连接数上限（DoS 防护——审计 P3 #18）。
    public var maxConnections: Int = 16
    /// 会话时长（默认 30 分钟）。
    public var sessionLifetime: TimeInterval = 30 * 60
    /// 接收目录。
    public let incomingDirectory: URL
    /// 供下载的共享文件目录。
    public let sharedDirectory: URL

    /// 传输记录回调（模块入库用）。
    public var onTransfer: (@Sendable (_ direction: String, _ filename: String, _ bytes: Int64, _ peer: String) -> Void)?

    public init(
        incomingDirectory: URL = AppEnvironment.transfersDirectory.appendingPathComponent("Incoming", isDirectory: true),
        sharedDirectory: URL = AppEnvironment.transfersDirectory.appendingPathComponent("Shared", isDirectory: true)
    ) {
        self.incomingDirectory = incomingDirectory
        self.sharedDirectory = sharedDirectory
        try? FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
    }

    public var session: Session? {
        lock.lock(); defer { lock.unlock() }
        if let session = _session, !session.isValid() {
            _session = nil
            return nil
        }
        return _session
    }

    /// 创建/重置会话，返回令牌。
    @discardableResult
    public func newSession() -> String {
        let token = Self.randomToken()
        lock.lock()
        _session = Session(token: token, createdAt: Date(), expiresAt: Date().addingTimeInterval(sessionLifetime))
        lock.unlock()
        return token
    }

    public func invalidateSession() {
        lock.lock(); _session = nil; lock.unlock()
    }

    /// 测试辅助：把当前会话改为立即过期。
    func setExpiry(_ date: Date) {
        lock.lock()
        if let current = _session {
            _session = Session(token: current.token, createdAt: current.createdAt, expiresAt: date)
        }
        lock.unlock()
    }

    /// 常量时间字符串比较（长度差先行，比较本身不短路）。
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 生命周期

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port?.rawValue {
                self?.lock.lock()
                self?.port = port
                self?.lock.unlock()
                Log.info("NearLink 服务已启动，端口 \(port)", category: .network)
            }
            if case .failed(let error) = state {
                Log.error("NearLink 服务失败: \(String(describing: error))", category: .network)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    public func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        port = 0
        lock.unlock()
    }

    // MARK: - 连接处理

    private func handleConnection(_ connection: NWConnection) {
        lock.lock()
        guard connections.count < maxConnections else {
            lock.unlock()
            connection.cancel()
            Log.warning("NearLink 拒绝连接（超出上限 \(maxConnections)）", category: .network)
            return
        }
        connections.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state, let connection {
                self?.removeConnection(connection)
            }
            if case .cancelled = state, let connection {
                self?.removeConnection(connection)
            }
        }
        connection.start(queue: .global(qos: .utility))
        receiveRequest(connection: connection, buffer: Data())
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
                // 请求体上限保护
                if accumulated.count > self.maxBodyBytes + 64 * 1024 {
                    self.respond(connection: connection, status: "413 Payload Too Large", contentType: "text/plain; charset=utf-8", body: Data("请求体过大".utf8))
                    return
                }
            }
            if let request = self.parseRequest(from: accumulated) {
                self.route(request: request, connection: connection)
                return
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(connection: connection, buffer: accumulated)
        }
    }

    // MARK: - HTTP 解析

    struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    /// 请求完整性判断：头部结束且 body 达到 Content-Length（或无 body）。
    func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else { return nil }
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: contentLength))

        // 解析 query
        var path = target
        var query: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[..<questionMark])
            let queryString = String(target[target.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1)
                guard let key = keyValue.first.map(String.init)?.removingPercentEncoding,
                      !key.isEmpty else { continue }
                let value = keyValue.count > 1 ? (String(keyValue[1]).removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }
        // 路径穿越防护
        if path.contains("..") {
            path = "/"
        }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    // MARK: - 路由

    private func route(request: HTTPRequest, connection: NWConnection) {
        let peer = connection.endpoint.debugDescription
        // 令牌校验（所有业务路由）；常量时间比较防时序侧信道（审计 P3 #12）
        guard let session = session,
              Self.constantTimeEquals(request.query["t"] ?? "", session.token) else {
            respond(connection: connection, status: "403 Forbidden", contentType: "text/html; charset=utf-8",
                    body: Data("<html><body><h1>403</h1><p>需要有效访问令牌（请重新扫码）。</p></body></html>".utf8))
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            respond(connection: connection, status: "200 OK", contentType: "text/html; charset=utf-8",
                    body: Self.indexPageHTML(token: session.token))
        case ("GET", "/files"):
            let list = sharedFilesJSON()
            respond(connection: connection, status: "200 OK", contentType: "application/json; charset=utf-8", body: list)
        case ("GET", "/download"):
            handleDownload(request: request, connection: connection)
        case ("POST", "/upload"):
            handleUpload(request: request, connection: connection, peer: peer)
        case ("POST", "/text"):
            handleText(request: request, connection: connection, peer: peer)
        default:
            respond(connection: connection, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
        }
    }

    // MARK: - 业务处理

    private func handleDownload(request: HTTPRequest, connection: NWConnection) {
        guard let id = request.query["id"], !id.isEmpty,
              !id.contains("/"), !id.contains(".."),
              !id.contains("\""), !id.contains("\r"), !id.contains("\n") else {
            respond(connection: connection, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("无效的文件 ID".utf8))
            return
        }
        let url = sharedDirectory.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: url.path),
              let fileAttributes = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let totalBytes = fileAttributes.fileSize else {
            respond(connection: connection, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("文件不存在".utf8))
            return
        }
        let mime = Self.mimeType(forExtension: (id as NSString).pathExtension)
        // filename* 按 RFC 5987 编码，杜绝响应头注入（审计 #5）
        let encodedName = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        var header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(totalBytes)\r\n"
        header += "Content-Disposition: attachment; filename*=UTF-8''\(encodedName)\r\n\r\n"
        // 流式发送：先头后体，分块避免 2× 文件大小内存峰值（审计 #8）
        let fileBox = FileStreamBox(url: url)
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak connection] _ in
            guard let connection else { return }
            Self.streamFile(fileBox, to: connection)
        })
        onTransfer?("send", id, Int64(totalBytes), "browser")
    }

    private func handleUpload(request: HTTPRequest, connection: NWConnection, peer: String) {
        guard let contentType = request.headers["content-type"],
              contentType.contains("multipart/form-data") else {
            respond(connection: connection, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("需要 multipart/form-data".utf8))
            return
        }
        let saved = Self.parseMultipartFile(body: request.body, contentType: contentType)
        guard let (filename, fileData) = saved, !filename.isEmpty, !filename.hasPrefix(".") else {
            respond(connection: connection, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("未找到文件字段".utf8))
            return
        }
        // 文件名安全化
        let safeName = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        // TOCTOU 防护：先写唯一临时名，再串行区（actor 内 uniqueDestination）改名（审计 #11）
        let tempTarget = incomingDirectory.appendingPathComponent(".upload-\(UUID().uuidString).tmp")
        do {
            try fileData.write(to: tempTarget, options: .atomic)
            try FileSafety.validateOutput(at: tempTarget)
            let destination = FileSafety.uniqueDestination(in: incomingDirectory, preferredName: safeName)
            try FileManager.default.moveItem(at: tempTarget, to: destination)
            onTransfer?("receive", destination.lastPathComponent, Int64(fileData.count), peer)
            respond(connection: connection, status: "200 OK", contentType: "application/json; charset=utf-8",
                    body: Data("{\"ok\":true,\"name\":\"\(destination.lastPathComponent)\"}".utf8))
        } catch {
            try? FileManager.default.removeItem(at: tempTarget)
            respond(connection: connection, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8",
                    body: Data("保存失败".utf8))
        }
    }

    private func handleText(request: HTTPRequest, connection: NWConnection, peer: String) {
        let text = String(data: request.body, encoding: .utf8) ?? ""
        guard !text.isEmpty else {
            respond(connection: connection, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("内容为空".utf8))
            return
        }
        let filename = "文本-\(Int(Date().timeIntervalSince1970)).txt"
        let destination = FileSafety.uniqueDestination(in: incomingDirectory, preferredName: filename)
        do {
            try text.data(using: .utf8)?.write(to: destination, options: .atomic)
            try FileSafety.validateOutput(at: destination)
        } catch {
            respond(connection: connection, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8",
                    body: Data("保存失败".utf8))
            return
        }
        onTransfer?("receive-text", destination.lastPathComponent, Int64(text.utf8.count), peer)
        respond(connection: connection, status: "200 OK", contentType: "application/json; charset=utf-8",
                body: Data("{\"ok\":true}".utf8))
    }

    struct SharedFile: Codable {
        let name: String
        let size: Int
    }

    /// 文件列表 JSON（JSONEncoder 保证转义——审计 #4）
    func sharedFilesJSON() -> Data {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: sharedDirectory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { name -> SharedFile in
                let url = sharedDirectory.appendingPathComponent(name)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return SharedFile(name: name, size: size)
            }
        return (try? JSONEncoder().encode(files)) ?? Data("[]".utf8)
    }

    /// 文件流装箱（InputStream 非 Sendable，经 @unchecked Sendable 箱跨并发域）。
    private final class FileStreamBox: @unchecked Sendable {
        let url: URL
        init(url: URL) { self.url = url }
    }

    /// 分块发送文件直到 EOF。
    private static func streamFile(_ box: FileStreamBox, to connection: NWConnection) {
        guard let stream = InputStream(url: box.url) else {
            connection.cancel()
            return
        }
        stream.open()
        defer { stream.close() }
        let bufferSize = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        let semaphore = DispatchSemaphore(value: 0)
        func sendNextChunk() {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                semaphore.signal()
                return
            }
            connection.send(content: Data(bytes: buffer, count: read), completion: .contentProcessed { _ in
                sendNextChunk()
            })
        }
        sendNextChunk()
        semaphore.wait()
        connection.cancel()
    }

    // MARK: - 响应

    private func respond(connection: NWConnection, status: String?, contentType: String?, body: Data) {
        var response = Data()
        if let status {
            let type = contentType ?? "text/plain; charset=utf-8"
            response.append(Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        }
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    // MARK: - 邀请信息

    /// 局域网 IP（首个非回环 IPv4）。
    public static func lanAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = current.pointee.ifa_addr else { continue }
            if interface.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name == "en0" || name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(interface, socklen_t(interface.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let candidate = String(cString: host)
                        if !candidate.hasPrefix("127.") {
                            address = candidate
                            if name == "en0" { break }
                        }
                    }
                }
            }
        }
        return address
    }

    /// 生成邀请二维码负载（http://ip:port/?t=token）。
    public func invitationURL() -> String? {
        guard let session = session, port != 0, let ip = Self.lanAddress() else { return nil }
        return "http://\(ip):\(port)/?t=\(session.token)"
    }

    // MARK: - HTML

    static func indexPageHTML(token: String) -> Data {
        let html = """
        <!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Deskvanic NearLink</title>
        <style>body{font-family:-apple-system,sans-serif;max-width:480px;margin:0 auto;padding:20px}
        input,button{font-size:16px;padding:10px;margin:6px 0;width:100%;box-sizing:border-box}
        button{background:#0a84ff;color:#fff;border:0;border-radius:8px}
        h2{font-size:18px}.muted{color:#888;font-size:13px}</style></head><body>
        <h2>Deskvanic · NearLink</h2>
        <p class="muted">本页仅在令牌有效期内可用。传输走局域网 HTTP+令牌（非加密通道）。</p>
        <form action="/upload?t=\(token)" method="post" enctype="multipart/form-data">
          <input type="file" name="file" required>
          <button type="submit">上传文件</button>
        </form>
        <h2>发送文本</h2>
        <form onsubmit="sendText(event)">
          <textarea id="text" rows="4" style="width:100%" placeholder="输入要发送的文字"></textarea>
          <button type="submit">发送文本</button>
        </form>
        <h2>下载（Mac 共享）</h2>
        <ul id="files"></ul>
        <script>
        function sendText(e){e.preventDefault();
          fetch('/text?t=\(token)',{method:'POST',body:document.getElementById('text').value})
          .then(r=>r.json()).then(j=>{if(j.ok){alert('已发送');document.getElementById('text').value='';}});}
        fetch('/files?t=\(token)').then(r=>r.json()).then(files=>{
          const ul=document.getElementById('files');
          files.forEach(f=>{const li=document.createElement('li');
            const a=document.createElement('a');
            a.href='/download?t=\(token)&id='+encodeURIComponent(f.name);
            a.textContent=f.name;
            const span=document.createElement('span');
            span.className='muted'; span.textContent=' '+f.size+' B';
            li.appendChild(a); li.appendChild(span);
            ul.appendChild(li);});});
        </script></body></html>
        """
        return Data(html.utf8)
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "html": return "text/html"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Multipart

    /// 解析 multipart body 中第一个 file 字段（防误解析：严格 boundary 分割）。
    static func parseMultipartFile(body: Data, contentType: String) -> (String, Data)? {
        guard let boundaryLine = contentType.split(separator: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("boundary=") }) else {
            return nil
        }
        var boundary = boundaryLine.trimmingCharacters(in: .whitespaces)
        boundary.removeFirst("boundary=".count)
        let delimiter = Data("--\(boundary)".utf8)

        var searchRange = body.startIndex..<body.endIndex
        // 找到第一个 part
        guard let firstPart = body.range(of: delimiter, in: searchRange) else { return nil }
        searchRange = firstPart.upperBound..<body.endIndex
        guard let headersEnd = body.range(of: Data("\r\n\r\n".utf8), in: searchRange) else { return nil }
        let partHeaders = String(data: body.subdata(in: firstPart.upperBound..<headersEnd.lowerBound), encoding: .utf8) ?? ""

        // 提取 filename
        guard let filenameRange = partHeaders.range(of: "filename=\"") else { return nil }
        let afterFilename = partHeaders[filenameRange.upperBound...]
        guard let quoteEnd = afterFilename.firstIndex(of: "\"") else { return nil }
        let filename = String(afterFilename[..<quoteEnd])

        // part 内容到下一个 boundary
        let contentStart = headersEnd.upperBound
        guard let nextBoundary = body.range(of: delimiter, in: contentStart..<body.endIndex) else { return nil }
        var content = body.subdata(in: contentStart..<nextBoundary.lowerBound)
        // 去掉尾部 \r\n
        if content.suffix(2) == Data("\r\n".utf8) {
            content = content.dropLast(2)
        }
        return (filename, content)
    }
}
