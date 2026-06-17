package com.huangjx.media_play.smb

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView

class SmbPlayerActivity : Activity() {
    private var player: ExoPlayer? = null
    private var playerView: PlayerView? = null
    private var httpServer: NativeSmbHttpServer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID).orEmpty()
        val paths = intent.getStringArrayListExtra(EXTRA_PATHS).orEmpty()
        val names = intent.getStringArrayListExtra(EXTRA_NAMES).orEmpty()
        val initialIndex = intent.getIntExtra(EXTRA_INITIAL_INDEX, 0)
            .coerceIn(0, (paths.size - 1).coerceAtLeast(0))
        val service = SmbPlaybackRegistry.service

        if (sessionId.isBlank() || paths.isEmpty() || service == null) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        val server = NativeSmbHttpServer(service)
        httpServer = server
        server.start()

        val view = PlayerView(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            keepScreenOn = true
            setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
        }
        playerView = view
        setContentView(view)

        val mediaItems = paths.mapIndexed { index, path ->
            val title = names.getOrNull(index).takeUnless { it.isNullOrBlank() }
                ?: path.substringAfterLast('\\').substringAfterLast('/')
            MediaItem.Builder()
                .setUri(server.buildUrl(sessionId, path, title))
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(title)
                        .build()
                )
                .build()
        }

        val exoPlayer = ExoPlayer.Builder(this).build().apply {
            setMediaItems(mediaItems, initialIndex, 0L)
            prepare()
            playWhenReady = true
        }
        player = exoPlayer
        view.player = exoPlayer
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            releasePlayer()
        }
    }

    override fun onDestroy() {
        releasePlayer()
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onDestroy()
    }

    private fun releasePlayer() {
        playerView?.player = null
        player?.release()
        player = null
        httpServer?.stop()
        httpServer = null
    }

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_NAMES = "names"
        const val EXTRA_INITIAL_INDEX = "initial_index"
    }
}
