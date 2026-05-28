package com.huangjx.media_play.smb

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.webkit.MimeTypeMap
import java.io.InputStream
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * ContentProvider that serves SMB files as content:// URIs.
 *
 * URI format: content://com.huangjx.media_play.smb.provider/{sessionId}/{encodedPath}
 *
 * Example usage:
 *   content://com.huangjx.media_play.smb.provider/abc123/myshare%5Cmovies%5Cvideo.mkv
 */
class SmbContentProvider : ContentProvider() {

    companion object {
        const val AUTHORITY = "com.huangjx.media_play.smb.provider"
        private const val CONTENT_SCHEME = "content"
        private const val BUFFER_SIZE = 8192

        private var smbService: SmbService? = null

        /**
         * Must be called before the provider is used.
         * Sets the SmbService instance that this provider uses to read files.
         */
        fun init(service: SmbService) {
            smbService = service
        }

        /**
         * Builds a content URI for a given session and SMB path.
         *
         * @param sessionId The SMB session ID
         * @param path The SMB path (e.g. "shareName\folder\file.ext")
         * @return A content:// URI
         */
        fun buildUri(sessionId: String, path: String): Uri {
            val encodedPath = URLEncoder.encode(path, "UTF-8")
            return Uri.Builder()
                .scheme(CONTENT_SCHEME)
                .authority(AUTHORITY)
                .appendPath(sessionId)
                .appendPath(encodedPath)
                .build()
        }
    }

    override fun onCreate(): Boolean {
        return true
    }

    /**
     * Opens the SMB file specified by the URI and returns a ParcelFileDescriptor
     * for reading. Data is streamed from SMB on a background thread through a pipe.
     */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val service = smbService
            ?: throw IllegalStateException("SmbContentProvider not initialized. Call SmbContentProvider.init() first.")

        val (sessionId, path) = parseUri(uri)

        // Check for Range request in extras (via AssetFileDescriptor pattern)
        var offset = 0L
        var length = -1L

        // Try to read range from query parameters
        uri.getQueryParameter("offset")?.let { offset = it.toLongOrNull() ?: 0L }
        uri.getQueryParameter("length")?.let { length = it.toLongOrNull() ?: -1L }

        val pipe = ParcelFileDescriptor.createReliablePipe()
        val readFd = pipe[0]
        val writeFd = pipe[1]

        // Stream SMB data to the pipe on a background thread
        val thread = Thread {
            var smbStream: InputStream? = null
            try {
                smbStream = service.openRead(sessionId, path, offset, length)
                val outputStream = ParcelFileDescriptor.AutoCloseOutputStream(writeFd)
                val buffer = ByteArray(BUFFER_SIZE)
                var totalRead = 0L
                var bytesRead: Int

                while (true) {
                    // If length was specified, don't read more than requested
                    if (length > 0) {
                        val remaining = length - totalRead
                        if (remaining <= 0) break
                        val toRead = minOf(buffer.size.toLong(), remaining).toInt()
                        bytesRead = smbStream.read(buffer, 0, toRead)
                    } else {
                        bytesRead = smbStream.read(buffer)
                    }

                    if (bytesRead == -1) break

                    outputStream.write(buffer, 0, bytesRead)
                    totalRead += bytesRead
                }
                outputStream.flush()
                outputStream.close()
            } catch (e: Exception) {
                try { writeFd.close() } catch (_: Exception) {}
            } finally {
                try { smbStream?.close() } catch (_: Exception) {}
            }
        }
        thread.name = "SmbContentProvider-${sessionId}"
        thread.isDaemon = true
        thread.start()

        return readFd
    }

    /**
     * Returns the MIME type based on the file extension in the URI path.
     */
    override fun getType(uri: Uri): String? {
        val path = uri.lastPathSegment ?: return "application/octet-stream"
        val decoded = try {
            URLDecoder.decode(path, "UTF-8")
        } catch (_: Exception) {
            path
        }
        return getMimeTypeFromPath(decoded)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor? {
        throw UnsupportedOperationException("query not supported for SmbContentProvider")
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? {
        throw UnsupportedOperationException("insert not supported for SmbContentProvider")
    }

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        throw UnsupportedOperationException("delete not supported for SmbContentProvider")
    }

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int {
        throw UnsupportedOperationException("update not supported for SmbContentProvider")
    }

    /**
     * Parses the URI to extract sessionId and SMB path.
     * URI format: content://authority/{sessionId}/{encodedPath}
     */
    private fun parseUri(uri: Uri): Pair<String, String> {
        val segments = uri.pathSegments
        if (segments.size < 2) {
            throw IllegalArgumentException("Invalid SMB content URI: $uri. Expected format: content://$AUTHORITY/{sessionId}/{encodedPath}")
        }
        val sessionId = segments[0]
        val encodedPath = segments[1]
        val path = try {
            URLDecoder.decode(encodedPath, "UTF-8")
        } catch (_: Exception) {
            encodedPath
        }
        return Pair(sessionId, path)
    }

    private fun getMimeTypeFromPath(path: String): String {
        val dotIndex = path.lastIndexOf('.')
        if (dotIndex < 0) return "application/octet-stream"
        val extension = path.substring(dotIndex + 1).lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }
}
