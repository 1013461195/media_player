package com.huangjx.media_play.smb

import android.net.Uri
import android.util.Log
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import java.io.IOException

@UnstableApi
class SmbDataSource(
    private val smbService: SmbService,
    private val sessionId: String,
    private val path: String
) : BaseDataSource(true) {
    private var uri: Uri? = null
    private var handle: SmbFileHandle? = null
    private var readPosition = 0L
    private var bytesRemaining = 0L
    private var opened = false
    private var fileSize = 0L
    private var chunkStart = -1L
    private var chunkLength = 0
    private val chunk = ByteArray(CHUNK_SIZE)

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        uri = dataSpec.uri

        val fileHandle = smbService.openFile(sessionId, path)
        handle = fileHandle
        fileSize = fileHandle.size
        readPosition = dataSpec.position
        bytesRemaining = if (dataSpec.length == C.LENGTH_UNSET.toLong()) {
            (fileSize - dataSpec.position).coerceAtLeast(0L)
        } else {
            dataSpec.length
        }
        chunkStart = -1L
        chunkLength = 0

        opened = true
        transferStarted(dataSpec)
        return bytesRemaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT

        val fileHandle = handle ?: throw IOException("SMB file is not open")
        if (readPosition !in chunkStart until (chunkStart + chunkLength)) {
            val maxChunkRead = minOf(CHUNK_SIZE.toLong(), fileSize - readPosition).toInt()
            if (maxChunkRead <= 0) return C.RESULT_END_OF_INPUT
            val startedAt = System.currentTimeMillis()
            val read = fileHandle.readAt(readPosition, chunk, 0, maxChunkRead)
            if (read <= 0) return C.RESULT_END_OF_INPUT
            val elapsed = System.currentTimeMillis() - startedAt
            if (elapsed > 120) {
                Log.d(TAG, "slow SMB read bytes=$read offset=$readPosition elapsed=${elapsed}ms path=$path")
            }
            chunkStart = readPosition
            chunkLength = read
        }

        val chunkOffset = (readPosition - chunkStart).toInt()
        val available = chunkLength - chunkOffset
        val toCopy = minOf(length, available, bytesRemaining.toInt())
        System.arraycopy(chunk, chunkOffset, buffer, offset, toCopy)

        readPosition += toCopy
        bytesRemaining -= toCopy
        bytesTransferred(toCopy)
        return toCopy
    }

    override fun getUri(): Uri? = uri

    override fun close() {
        uri = null
        try {
            handle?.close()
        } finally {
            handle = null
            fileSize = 0L
            chunkStart = -1L
            chunkLength = 0
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }

    companion object {
        private const val TAG = "SmbDataSource"
        private const val CHUNK_SIZE = 1024 * 1024
    }
}

@UnstableApi
class SmbDataSourceFactory(
    private val smbService: SmbService,
    private val sessionId: String,
    private val path: String
) : DataSource.Factory {
    override fun createDataSource(): DataSource {
        return SmbDataSource(smbService, sessionId, path)
    }
}
