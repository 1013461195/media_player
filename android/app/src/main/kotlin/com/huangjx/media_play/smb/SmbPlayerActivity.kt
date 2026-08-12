package com.huangjx.media_play.smb

import android.app.Activity
import android.content.res.ColorStateList
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import com.huangjx.media_play.R
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import kotlin.math.abs

@UnstableApi
class SmbPlayerActivity : Activity() {
    private lateinit var smbService: SmbService
    private lateinit var sessionId: String
    private val paths = mutableListOf<String>()
    private val names = mutableListOf<String>()
    private var currentIndex = 0

    private var player: ExoPlayer? = null
    private lateinit var playerView: PlayerView
    private lateinit var overlay: FrameLayout
    private lateinit var titleView: TextView
    private lateinit var gestureView: TextView
    private lateinit var playlistScrim: View
    private lateinit var playlistPanel: LinearLayout
    private lateinit var positionView: TextView
    private lateinit var durationView: TextView
    private lateinit var progressBar: SeekBar
    private lateinit var audioManager: AudioManager
    private var playButton: ImageButton? = null
    private val progressHandler = Handler(Looper.getMainLooper())

    private var controlsVisible = true
    private var isLandscape = true
    private var downX = 0f
    private var downY = 0f
    private var startBrightness = 0.5f
    private var startVolume = 0
    private var maxVolume = 1
    private var gestureMode = GestureMode.NONE
    private var userSeeking = false
    private val progressTick = object : Runnable {
        override fun run() {
            updateProgress()
            progressHandler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        isLandscape = true

        val service = SmbPlaybackRegistry.service
        val sid = intent.getStringExtra(EXTRA_SESSION_ID)
        val incomingPaths = intent.getStringArrayListExtra(EXTRA_PATHS).orEmpty()
        val incomingNames = intent.getStringArrayListExtra(EXTRA_NAMES).orEmpty()
        if (service == null || sid.isNullOrBlank() || incomingPaths.isEmpty()) {
            Log.e(TAG, "Missing SMB playback arguments")
            setResult(RESULT_CANCELED)
            finish()
            return
        }

        smbService = service
        sessionId = sid
        paths.addAll(incomingPaths)
        names.addAll(incomingPaths.mapIndexed { index, path ->
            incomingNames.getOrNull(index)?.takeIf { it.isNotBlank() }
                ?: path.substringAfterLast('/').substringAfterLast('\\')
        })
        currentIndex = intent.getIntExtra(EXTRA_INITIAL_INDEX, 0).coerceIn(0, paths.lastIndex)
        audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)

        buildUi()
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                15_000,
                90_000,
                2_500,
                5_000
            )
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        player = ExoPlayer.Builder(this)
            .setLoadControl(loadControl)
            .build()
            .also { exoPlayer ->
                exoPlayer.addListener(object : Player.Listener {
                    override fun onPlayerError(error: PlaybackException) {
                        Log.e(TAG, "SMB native playback failed: ${error.message}", error)
                        Toast.makeText(this@SmbPlayerActivity, "Playback failed", Toast.LENGTH_SHORT).show()
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        updatePlayButton()
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        updateProgress()
                    }
                })
                playerView.player = exoPlayer
            }
        playCurrent()
        progressHandler.post(progressTick)
    }

    private fun buildUi() {
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        playerView = PlayerView(this).apply {
            useController = false
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        overlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        gestureView = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            textSize = 18f
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(28, 16, 28, 16)
        }

        root.addView(playerView)
        root.addView(overlay)
        root.addView(gestureView, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        ))
        root.setOnTouchListener { _, event -> handleTouch(event) }
        setContentView(root)
        buildControls()
    }

    private fun buildControls() {
        overlay.removeAllViews()

        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(0xDD000000.toInt())
            setPadding(dp(12), 0, dp(12), 0)
        }
        titleView = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 17f
            maxLines = 1
        }
        topBar.addView(iconButton(R.drawable.ic_arrow_back_24, "Back") { finish() })
        topBar.addView(titleView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        topBar.addView(iconButton(R.drawable.ic_playlist_24, "Playlist") { togglePlaylistPanel() })
        topBar.addView(iconButton(R.drawable.ic_delete_24, "Delete") { deleteCurrentAndPlayNext() })
        overlay.addView(topBar, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(56),
            Gravity.TOP
        ))

        val bottomPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xDD000000.toInt())
            setPadding(dp(22), dp(8), dp(22), dp(12))
        }
        val progressRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(4))
        }
        positionView = timeText()
        durationView = timeText()
        progressBar = SeekBar(this).apply {
            max = 1000
            progress = 0
            progressTintList = ColorStateList.valueOf(BLUE)
            thumbTintList = ColorStateList.valueOf(BLUE)
            progressBackgroundTintList = ColorStateList.valueOf(0xFF3A3A3A.toInt())
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        val duration = player?.duration?.takeIf { it > 0 } ?: return
                        positionView.text = formatTime(duration * progress / 1000)
                    }
                }

                override fun onStartTrackingTouch(seekBar: SeekBar?) {
                    userSeeking = true
                }

                override fun onStopTrackingTouch(seekBar: SeekBar?) {
                    val duration = player?.duration?.takeIf { it > 0 } ?: return
                    player?.seekTo(duration * (seekBar?.progress ?: 0) / 1000)
                    userSeeking = false
                    updateProgress()
                }
            })
        }
        progressRow.addView(positionView)
        progressRow.addView(progressBar, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        progressRow.addView(durationView)
        bottomPanel.addView(progressRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))

        val bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, 0)
        }
        bottomBar.addView(iconButton(R.drawable.ic_skip_previous_24, "Previous") { playAt(currentIndex - 1) })
        bottomBar.addView(iconButton(R.drawable.ic_replay_15_24, "Back 15 seconds") { seekBy(-15_000L) })
        playButton = iconButton(R.drawable.ic_pause_32, "Play or pause", large = true) { togglePlayPause() }
        bottomBar.addView(playButton)
        bottomBar.addView(iconButton(R.drawable.ic_forward_15_24, "Forward 15 seconds") { seekBy(15_000L) })
        bottomBar.addView(iconButton(R.drawable.ic_skip_next_24, "Next") { playAt(currentIndex + 1) })
        bottomBar.addView(iconButton(R.drawable.ic_playlist_24, "Playlist") { togglePlaylistPanel() })
        bottomBar.addView(iconButton(R.drawable.ic_fullscreen_24, "Rotate") { toggleOrientation() })
        bottomPanel.addView(bottomBar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        overlay.addView(bottomPanel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM
        ))
        buildPlaylistPanel()
    }

    private fun iconButton(
        iconRes: Int,
        description: String,
        large: Boolean = false,
        onClick: () -> Unit
    ): ImageButton {
        return ImageButton(this).apply {
            contentDescription = description
            setImageResource(iconRes)
            setColorFilter(Color.WHITE)
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = ImageView.ScaleType.CENTER
            layoutParams = LinearLayout.LayoutParams(
                if (large) dp(72) else dp(58),
                if (large) dp(58) else dp(52)
            )
            setOnClickListener { onClick() }
        }
    }

    private fun timeText(): TextView {
        return TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 14f
            text = "00:00"
            gravity = Gravity.CENTER
            minWidth = dp(70)
        }
    }

    private fun buildPlaylistPanel() {
        playlistScrim = View(this).apply {
            setBackgroundColor(Color.TRANSPARENT)
            visibility = View.GONE
            isClickable = true
            setOnClickListener {
                hidePlaylistPanel()
            }
        }
        overlay.addView(playlistScrim, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
        playlistPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xF0181818.toInt())
            visibility = View.GONE
            isClickable = true
        }
        overlay.addView(playlistPanel, FrameLayout.LayoutParams(
            dp(410),
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.END
        ))
        refreshPlaylistPanel()
    }

    private fun refreshPlaylistPanel() {
        if (!::playlistPanel.isInitialized) return
        playlistPanel.removeAllViews()
        playlistPanel.addView(TextView(this).apply {
            text = "当前目录 (${paths.size})"
            setTextColor(Color.WHITE)
            textSize = 19f
            setPadding(dp(26), dp(32), dp(18), dp(22))
        })

        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        paths.indices.forEach { index ->
            list.addView(playlistRow(index))
        }
        val scrollView = ScrollView(this).apply {
            addView(list)
        }
        playlistPanel.addView(scrollView, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            0,
            1f
        ))
    }

    private fun playlistRow(index: Int): View {
        val selected = index == currentIndex
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(if (selected) 0x333384FF else Color.TRANSPARENT)
            setPadding(dp(22), dp(14), dp(18), dp(14))
            isClickable = true
            setOnClickListener {
                hidePlaylistPanel()
                playAt(index)
            }

            addView(ImageView(this@SmbPlayerActivity).apply {
                setImageResource(if (selected) R.drawable.ic_play_arrow_32 else R.drawable.ic_movie_24)
                setColorFilter(if (selected) BLUE else Color.LTGRAY)
            }, LinearLayout.LayoutParams(dp(26), dp(26)))
            addView(TextView(this@SmbPlayerActivity).apply {
                text = names[index]
                setTextColor(if (selected) BLUE else Color.WHITE)
                textSize = 16f
                maxLines = 1
                setPadding(dp(16), 0, 0, 0)
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun togglePlaylistPanel() {
        if (playlistPanel.visibility == View.VISIBLE) {
            hidePlaylistPanel()
        } else {
            refreshPlaylistPanel()
            playlistScrim.visibility = View.VISIBLE
            playlistPanel.bringToFront()
            playlistPanel.visibility = View.VISIBLE
        }
    }

    private fun hidePlaylistPanel() {
        if (::playlistPanel.isInitialized) {
            playlistPanel.visibility = View.GONE
        }
        if (::playlistScrim.isInitialized) {
            playlistScrim.visibility = View.GONE
        }
    }

    private fun playCurrent() {
        if (paths.isEmpty()) {
            finish()
            return
        }
        val path = paths[currentIndex]
        val name = names[currentIndex]
        titleView.text = name
        if (::playlistPanel.isInitialized && playlistPanel.visibility == View.VISIBLE) {
            refreshPlaylistPanel()
        }

        val mediaSource = ProgressiveMediaSource.Factory(
            SmbDataSourceFactory(smbService, sessionId, path)
        ).createMediaSource(
            MediaItem.Builder()
                .setUri(Uri.parse("smb://local/${Uri.encode(name)}"))
                .setMediaMetadata(MediaMetadata.Builder().setTitle(name).build())
                .build()
        )

        player?.apply {
            stop()
            setMediaSource(mediaSource)
            playWhenReady = true
            prepare()
        }
        updatePlayButton()
        updateProgress()
    }

    private fun playAt(index: Int) {
        if (index !in paths.indices) return
        currentIndex = index
        playCurrent()
    }

    private fun deleteCurrentAndPlayNext() {
        if (paths.isEmpty()) return
        val deletePath = paths[currentIndex]
        player?.stop()
        player?.clearMediaItems()
        Thread {
            try {
                smbService.deleteFile(sessionId, deletePath)
                runOnUiThread {
                    paths.removeAt(currentIndex)
                    names.removeAt(currentIndex)
                    if (paths.isEmpty()) {
                        finish()
                    } else {
                        if (currentIndex >= paths.size) currentIndex = paths.lastIndex
                        refreshPlaylistPanel()
                        playCurrent()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Delete failed: ${e.message}", e)
                runOnUiThread {
                    Toast.makeText(this, "Delete failed: ${e.message}", Toast.LENGTH_SHORT).show()
                    playCurrent()
                }
            }
        }.start()
    }

    private fun seekBy(deltaMs: Long) {
        val current = player ?: return
        val duration = current.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
        current.seekTo((current.currentPosition + deltaMs).coerceIn(0L, duration))
    }

    private fun togglePlayPause() {
        val current = player ?: return
        if (current.isPlaying) current.pause() else current.play()
        updatePlayButton()
    }

    private fun toggleOrientation() {
        isLandscape = !isLandscape
        requestedOrientation = if (isLandscape) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        }
    }

    private fun handleTouch(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x
                downY = event.y
                gestureMode = GestureMode.NONE
                startBrightness = currentBrightness()
                startVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - downX
                val dy = event.y - downY
                if (gestureMode == GestureMode.NONE) {
                    if (abs(dx) < 24 && abs(dy) < 24) return true
                    gestureMode = if (abs(dy) > abs(dx)) {
                        if (downX < resources.displayMetrics.widthPixels / 2f) GestureMode.BRIGHTNESS else GestureMode.VOLUME
                    } else {
                        GestureMode.IGNORE
                    }
                }
                if (gestureMode == GestureMode.BRIGHTNESS) {
                    val next = (startBrightness - dy / resources.displayMetrics.heightPixels).coerceIn(0.02f, 1f)
                    val attrs = window.attributes
                    attrs.screenBrightness = next
                    window.attributes = attrs
                    showGesture("Brightness ${(next * 100).toInt()}%")
                } else if (gestureMode == GestureMode.VOLUME) {
                    val next = (startVolume - dy / resources.displayMetrics.heightPixels * maxVolume).toInt().coerceIn(0, maxVolume)
                    audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, next, 0)
                    showGesture("Volume ${(next * 100 / maxVolume)}%")
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (abs(event.x - downX) < 16 && abs(event.y - downY) < 16) {
                    controlsVisible = !controlsVisible
                    overlay.visibility = if (controlsVisible) View.VISIBLE else View.GONE
                    if (controlsVisible && playlistPanel.visibility == View.VISIBLE) {
                        playlistScrim.visibility = View.VISIBLE
                        playlistPanel.bringToFront()
                    }
                }
                gestureView.visibility = View.GONE
                gestureMode = GestureMode.NONE
                return true
            }
        }
        return true
    }

    private fun currentBrightness(): Float {
        val value = window.attributes.screenBrightness
        return if (value >= 0f) value else 0.5f
    }

    private fun showGesture(text: String) {
        gestureView.text = text
        gestureView.visibility = View.VISIBLE
    }

    private fun updatePlayButton() {
        val icon = if (player?.isPlaying == true) {
            R.drawable.ic_pause_32
        } else {
            R.drawable.ic_play_arrow_32
        }
        playButton?.setImageResource(icon)
    }

    private fun updateProgress() {
        if (!::progressBar.isInitialized || userSeeking) return
        val current = player ?: return
        val duration = current.duration.takeIf { it > 0 } ?: 0L
        val position = current.currentPosition.coerceAtLeast(0L)
        positionView.text = formatTime(position)
        durationView.text = if (duration > 0) formatTime(duration) else "--:--"
        progressBar.progress = if (duration > 0) {
            (position * 1000 / duration).toInt().coerceIn(0, 1000)
        } else {
            0
        }
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = (ms / 1000).coerceAtLeast(0L)
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return if (hours > 0) {
            "%d:%02d:%02d".format(hours, minutes, seconds)
        } else {
            "%02d:%02d".format(minutes, seconds)
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onDestroy() {
        progressHandler.removeCallbacks(progressTick)
        player?.release()
        player = null
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setResult(RESULT_OK)
        super.onDestroy()
    }

    private enum class GestureMode {
        NONE,
        BRIGHTNESS,
        VOLUME,
        IGNORE
    }

    companion object {
        const val EXTRA_SESSION_ID = "sessionId"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_NAMES = "names"
        const val EXTRA_INITIAL_INDEX = "initialIndex"
        private const val BLUE = 0xFF2E86FF.toInt()
        private const val TAG = "SmbNativePlayer"
    }
}
