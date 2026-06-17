package com.huangjx.media_play.smb

object SmbPlaybackRegistry {
    @Volatile
    var service: SmbService? = null
}
