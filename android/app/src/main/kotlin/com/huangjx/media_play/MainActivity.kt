package com.huangjx.media_play

import android.os.Build
import android.view.Display
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.huangjx.media_play.smb.SmbService
import com.huangjx.media_play.smb.SmbContentProvider
import com.huangjx.media_play.smb.NativeSmbHttpServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val HDR_CHANNEL = "com.huangjx.media_play/hdr"
    private val SMB_CHANNEL = "com.huangjx.media_play/smb"

    private val smbService = SmbService()
    private val httpServer = NativeSmbHttpServer(smbService)
    private val scope = CoroutineScope(Dispatchers.IO)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize the ContentProvider with the SmbService instance
        SmbContentProvider.init(smbService)

        // HDR channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HDR_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkDolbyVisionSupport" -> {
                    result.success(isDolbyVisionSupported())
                }
                "checkHdrSupport" -> {
                    result.success(isHdrSupported())
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // SMB channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMB_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "smbConnect" -> {
                    val host = call.argument<String>("host") ?: ""
                    val domain = call.argument<String>("domain") ?: ""
                    val username = call.argument<String>("username") ?: ""
                    val password = call.argument<String>("password") ?: ""
                    scope.launch {
                        try {
                            val sessionId = smbService.connect(host, domain, username, password)
                            withContext(Dispatchers.Main) { result.success(sessionId) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SMB_CONNECT_ERROR", e.message, null) }
                        }
                    }
                }
                "smbListFiles" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    scope.launch {
                        try {
                            val files = smbService.listFiles(sessionId, path)
                            withContext(Dispatchers.Main) { result.success(files) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SMB_LIST_ERROR", e.message, null) }
                        }
                    }
                }
                "smbDisconnect" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    scope.launch {
                        try {
                            smbService.disconnect(sessionId)
                            withContext(Dispatchers.Main) { result.success(null) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SMB_DISCONNECT_ERROR", e.message, null) }
                        }
                    }
                }
                "smbDeleteFile" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    scope.launch {
                        try {
                            smbService.deleteFile(sessionId, path)
                            withContext(Dispatchers.Main) { result.success(null) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SMB_DELETE_ERROR", e.message, null) }
                        }
                    }
                }
                "smbGetFileSize" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    scope.launch {
                        try {
                            val size = smbService.getFileSize(sessionId, path)
                            withContext(Dispatchers.Main) { result.success(size) }
                        } catch (e: Exception) {
                            withContext(Dispatchers.Main) { result.error("SMB_SIZE_ERROR", e.message, null) }
                        }
                    }
                }
                "smbGetContentUri" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    try {
                        val uri = SmbContentProvider.buildUri(sessionId, path)
                        result.success(uri.toString())
                    } catch (e: Exception) {
                        result.error("SMB_URI_ERROR", e.message, null)
                    }
                }
                "smbStartHttpServer" -> {
                    try {
                        val port = httpServer.start()
                        result.success(port)
                    } catch (e: Exception) {
                        result.error("SMB_HTTP_START_ERROR", e.message, null)
                    }
                }
                "smbStopHttpServer" -> {
                    try {
                        httpServer.stop()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SMB_HTTP_STOP_ERROR", e.message, null)
                    }
                }
                "smbGetHttpUrl" -> {
                    val sessionId = call.argument<String>("sessionId") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    val fileName = call.argument<String>("fileName") ?: ""
                    try {
                        val url = httpServer.buildUrl(sessionId, path, fileName)
                        result.success(url)
                    } catch (e: Exception) {
                        result.error("SMB_HTTP_URL_ERROR", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun isDolbyVisionSupported(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val display = windowManager.defaultDisplay
            val hdrCapabilities = display.hdrCapabilities
            hdrCapabilities?.supportedHdrTypes?.any { it == Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION } ?: false
        } else {
            false
        }
    }

    private fun isHdrSupported(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val display = windowManager.defaultDisplay
            val hdrCapabilities = display.hdrCapabilities
            hdrCapabilities?.supportedHdrTypes?.isNotEmpty() ?: false
        } else {
            false
        }
    }
}
