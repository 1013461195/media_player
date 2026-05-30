package com.huangjx.media_play.smb

import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.LinkedHashMap
import java.util.concurrent.Executors

/**
 * Lightweight HTTP server that streams files from an SMB share using SMBJ.
 * Supports Range requests for seekable playback in media_kit/libmpv.
 */
class NativeSmbHttpServer(private val smbService: SmbService) {

    private var serverSocket: ServerSocket? = null
    private val executor = Executors.newCachedThreadPool()
    private val handleCache = object : LinkedHashMap<String, CachedSmbFile>(8, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedSmbFile>): Boolean {
            if (size <= MAX_CACHED_HANDLES) return false
            eldest.value.close()
            return true
        }
    }

    /**
     * Starts the HTTP server on a random available port.
     * Returns the port number.
     */
    fun start(): Int {
        val existing = serverSocket
        if (existing != null && !existing.isClosed) return existing.localPort
        val ss = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        serverSocket = ss
        executor.submit { acceptLoop(ss) }
        return ss.localPort
    }

    fun stop() {
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        synchronized(handleCache) {
            handleCache.values.forEach { it.close() }
            handleCache.clear()
        }
    }

    val port: Int get() = serverSocket?.localPort ?: 0

    /**
     * Builds a URL for streaming a file.
     */
    fun buildUrl(sessionId: String, path: String, fileName: String): String {
        val encodedPath = java.net.URLEncoder.encode(path, "UTF-8")
        val encodedName = java.net.URLEncoder.encode(fileName, "UTF-8")
        return "http://127.0.0.1:$port/video?s=$sessionId&p=$encodedPath&n=$encodedName"
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (!ss.isClosed) {
            try {
                val socket = ss.accept()
                executor.submit { handleConnection(socket) }
            } catch (_: Exception) {
                break
            }
        }
    }

    private fun handleConnection(socket: Socket) {
        var output: OutputStream? = null
        var responseStarted = false
        try {
            socket.soTimeout = 60_000
            val input = socket.getInputStream().buffered()
            output = socket.getOutputStream()
            val t0 = System.currentTimeMillis()

            // Read request line
            val requestLine = readLine(input) ?: return
            val parts = requestLine.split(" ", limit = 3)
            if (parts.size < 2) return
            val method = parts[0]
            val uri = parts[1]

            // Read headers
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) {
                    headers[line.substring(0, colon).trim().lowercase()] = line.substring(colon + 1).trim()
                }
            }

            // Parse URI
            val queryStart = uri.indexOf('?')
            val queryString = if (queryStart >= 0) uri.substring(queryStart + 1) else ""
            val params = parseQuery(queryString)
            val sessionId = params["s"]
            val encodedPath = params["p"]

            if (sessionId == null || encodedPath == null) {
                sendError(output, 400, "Missing parameters")
                return
            }
            val path = URLDecoder.decode(encodedPath, "UTF-8")

            // Open file once — get size from handle, no extra round trip
            val cacheKey = "$sessionId|$path"
            val activeFile = cachedFile(cacheKey, sessionId, path)
            val totalSize = activeFile.size
            val t1 = System.currentTimeMillis()
            android.util.Log.d("SmbHttp", "open+size=${t1-t0}ms path=$path size=$totalSize range=${headers["range"]}")
            val rangeHeader = headers["range"]
            val (start, end) = parseRange(rangeHeader, totalSize)
            val contentLength = end - start + 1
            val hasRange = rangeHeader != null
            val contentType = activeFile.contentType

            // Send response
            val sb = StringBuilder()
            sb.append(if (hasRange) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
            sb.append("Accept-Ranges: bytes\r\n")
            sb.append("Content-Type: $contentType\r\n")
            sb.append("Content-Length: $contentLength\r\n")
            if (hasRange) {
                sb.append("Content-Range: bytes $start-$end/$totalSize\r\n")
            }
            sb.append("Connection: close\r\n")
            sb.append("\r\n")
            output.write(sb.toString().toByteArray())
            output.flush()
            responseStarted = true

            if (method == "HEAD") {
                return
            }

            // Stream file data using random-access read (O(1) seek)
            val buffer = ByteArray(STREAM_BUFFER_SIZE)
            var fileOffset = start
            var remaining = contentLength
            var totalWritten = 0L
            while (remaining > 0) {
                val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                val read = activeFile.readAt(fileOffset, buffer, 0, toRead)
                if (read == -1) break
                output.write(buffer, 0, read)
                fileOffset += read
                remaining -= read
                totalWritten += read
            }
            output.flush()
            val t2 = System.currentTimeMillis()
            android.util.Log.d("SmbHttp", "done wrote=$totalWritten total=${t2-t0}ms")
        } catch (e: Exception) {
            android.util.Log.e("SmbHttp", "stream failed: ${e.message}", e)
            if (!responseStarted) {
                try { output?.let { sendError(it, 500, "SMB stream failed") } } catch (_: Exception) {}
            }
        } finally {
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun sendError(output: OutputStream, code: Int, message: String) {
        val body = "$code $message"
        val response = "HTTP/1.1 $code $message\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body"
        try {
            output.write(response.toByteArray())
            output.flush()
        } catch (_: Exception) {}
    }

    private fun readLine(input: java.io.BufferedInputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c == -1) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\r'.code) {
                val next = input.read()
                if (next != '\n'.code && next != -1) {
                    sb.append(c.toChar())
                    sb.append(next.toChar())
                }
                return sb.toString()
            }
            if (c == '\n'.code) return sb.toString()
            sb.append(c.toChar())
        }
    }

    private fun parseQuery(query: String): Map<String, String> {
        if (query.isEmpty()) return emptyMap()
        return query.split("&").associate {
            val parts = it.split("=", limit = 2)
            val key = URLDecoder.decode(parts[0], "UTF-8")
            val value = if (parts.size > 1) URLDecoder.decode(parts[1], "UTF-8") else ""
            key to value
        }
    }

    private fun parseRange(header: String?, total: Long): Pair<Long, Long> {
        if (header == null || total <= 0) return Pair(0, total - 1)
        val match = Regex("^bytes=(\\d*)-(\\d*)$").find(header.trim()) ?: return Pair(0, total - 1)
        val startStr = match.groupValues[1]
        val endStr = match.groupValues[2]
        if (startStr.isEmpty() && endStr.isEmpty()) return Pair(0, total - 1)

        val start: Long
        val end: Long
        if (startStr.isEmpty()) {
            val suffix = endStr.toLongOrNull() ?: return Pair(0, total - 1)
            start = (total - suffix).coerceAtLeast(0)
            end = total - 1
        } else {
            start = startStr.toLongOrNull() ?: return Pair(0, total - 1)
            end = if (endStr.isEmpty()) total - 1 else (endStr.toLongOrNull() ?: total - 1)
        }
        return Pair(start, end.coerceIn(start, total - 1))
    }

    private fun guessContentType(path: String): String {
        val ext = path.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "mp4" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "avi" -> "video/x-msvideo"
            "mov" -> "video/quicktime"
            "wmv" -> "video/x-ms-wmv"
            "flv" -> "video/x-flv"
            "webm" -> "video/webm"
            "ts" -> "video/mp2t"
            "m4v" -> "video/mp4"
            "mp3" -> "audio/mpeg"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "aac" -> "audio/aac"
            "ogg" -> "audio/ogg"
            else -> "application/octet-stream"
        }
    }

    private fun cachedFile(cacheKey: String, sessionId: String, path: String): CachedSmbFile {
        synchronized(handleCache) {
            handleCache[cacheKey]?.let { return it }
        }

        val handle = smbService.openFile(sessionId, path)
        val cached = CachedSmbFile(handle, handle.size, guessContentType(path))
        synchronized(handleCache) {
            handleCache[cacheKey]?.let {
                cached.close()
                return it
            }
            handleCache[cacheKey] = cached
            return cached
        }
    }

    private class CachedSmbFile(
        private val handle: SmbFileHandle,
        val size: Long,
        val contentType: String
    ) {
        fun readAt(fileOffset: Long, buffer: ByteArray, offset: Int, length: Int): Int {
            return handle.readAt(fileOffset, buffer, offset, length)
        }

        fun close() {
            handle.close()
        }
    }

    companion object {
        private const val STREAM_BUFFER_SIZE = 1024 * 1024
        private const val MAX_CACHED_HANDLES = 4
    }
}
