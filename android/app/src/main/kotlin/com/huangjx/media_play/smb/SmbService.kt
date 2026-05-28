package com.huangjx.media_play.smb

import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msdtyp.FileTime
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.smb2.info.FileStandardInformation
import java.io.InputStream
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Holds the SMB connection state for a single session.
 * Shares are cached per share name for reuse.
 */
class SmbConnection(
    val connection: Connection,
    val session: Session,
    val client: SMBClient
) {
    private val shares = ConcurrentHashMap<String, DiskShare>()

    @Synchronized
    fun getOrConnectShare(shareName: String): DiskShare {
        return shares.getOrPut(shareName) {
            session.connectShare(shareName) as DiskShare
        }
    }

    @Synchronized
    fun closeAll() {
        shares.values.forEach { try { it.close() } catch (_: Exception) {} }
        shares.clear()
        try { session.close() } catch (_: Exception) {}
        try { connection.close() } catch (_: Exception) {}
        try { client.close() } catch (_: Exception) {}
    }
}

class SmbService {

    private val sessions = ConcurrentHashMap<String, SmbConnection>()

    /**
     * Connects to an SMB server and returns a session ID.
     * The path provided to other methods should be in the form "shareName\folder\file".
     */
    fun connect(host: String, domain: String, username: String, password: String): String {
        val config = SmbConfig.builder().build()
        val client = SMBClient(config)
        val connection = client.connect(host)
        val ac = AuthenticationContext(username, password.toCharArray(), domain)
        val session = connection.authenticate(ac)

        val sessionId = UUID.randomUUID().toString()
        sessions[sessionId] = SmbConnection(connection, session, client)
        return sessionId
    }

    /**
     * Lists files in a directory on the SMB share.
     * Path format: "shareName\directory" (e.g. "myshare\movies\avatar")
     * or just "shareName" to list the root of the share.
     */
    fun listFiles(sessionId: String, path: String): List<Map<String, Any>> {
        val conn = getSession(sessionId)
        val (shareName, dirPath) = parsePath(path)
        val share = conn.getOrConnectShare(shareName)
        val result = mutableListOf<Map<String, Any>>()

        for (info in share.list(dirPath)) {
            val fileName = info.fileName
            if (fileName == "." || fileName == "..") continue

            val attrs = info.fileAttributes
            val isDir = (attrs and 0x10L) != 0L
            val isReadonly = (attrs and 0x01L) != 0L

            val fullPath = if (dirPath.isEmpty() || dirPath == "\\") {
                "$shareName\\$fileName"
            } else {
                "$shareName\\$dirPath\\$fileName"
            }

            val entry = mapOf(
                "name" to fileName,
                "path" to fullPath,
                "size" to info.allocationSize,
                "isDirectory" to isDir,
                "createTime" to fileTimeToMillis(info.creationTime),
                "lastModified" to fileTimeToMillis(info.lastWriteTime),
                "isReadonly" to isReadonly
            )
            result.add(entry)
        }
        return result
    }

    /**
     * Disconnects a session and releases all resources.
     */
    fun disconnect(sessionId: String) {
        val conn = sessions.remove(sessionId) ?: return
        conn.closeAll()
    }

    /**
     * Deletes a file on the SMB share.
     * Path format: "shareName\path\to\file.ext"
     */
    fun deleteFile(sessionId: String, path: String) {
        val conn = getSession(sessionId)
        val (shareName, filePath) = parsePath(path)
        val share = conn.getOrConnectShare(shareName)
        share.rm(filePath)
    }

    /**
     * Opens a file for reading with optional range support.
     * Path format: "shareName\path\to\file.ext"
     */
    fun openRead(sessionId: String, path: String, offset: Long, length: Long): InputStream {
        val conn = getSession(sessionId)
        val (shareName, filePath) = parsePath(path)
        val share = conn.getOrConnectShare(shareName)
        val file = share.openFile(
            filePath,
            EnumSet.of(AccessMask.GENERIC_READ),
            emptySet(),
            EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
            EnumSet.of(SMB2CreateOptions.FILE_RANDOM_ACCESS),
            SMB2CreateDisposition.FILE_OPEN
        )
        val stream = file.inputStream
        if (offset > 0) {
            stream.skip(offset)
        }
        return stream
    }

    /**
     * Gets the size of a file in bytes.
     * Path format: "shareName\path\to\file.ext"
     */
    fun getFileSize(sessionId: String, path: String): Long {
        val conn = getSession(sessionId)
        val (shareName, filePath) = parsePath(path)
        val share = conn.getOrConnectShare(shareName)
        val file = share.openFile(
            filePath,
            EnumSet.of(AccessMask.GENERIC_READ),
            emptySet(),
            EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
            EnumSet.of(SMB2CreateOptions.FILE_RANDOM_ACCESS),
            SMB2CreateDisposition.FILE_OPEN
        )
        try {
            val standardInfo = file.getFileInformation(FileStandardInformation::class.java)
            return standardInfo.endOfFile
        } finally {
            file.close()
        }
    }

    private fun getSession(sessionId: String): SmbConnection {
        return sessions[sessionId]
            ?: throw IllegalArgumentException("Session not found: $sessionId")
    }

    /**
     * Parses a full path into (shareName, relativePath).
     * "myshare\movies\avatar" -> ("myshare", "movies\avatar")
     * "myshare" -> ("myshare", "")
     */
    private fun parsePath(fullPath: String): Pair<String, String> {
        val normalized = fullPath.replace("/", "\\")
        val idx = normalized.indexOf('\\')
        return if (idx < 0) {
            Pair(normalized, "")
        } else {
            Pair(normalized.substring(0, idx), normalized.substring(idx + 1))
        }
    }

    private fun fileTimeToMillis(ft: FileTime): Long {
        return ft.toEpochMillis()
    }
}
