package com.wiantribe.home_listen

import android.os.Handler
import android.os.Looper
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/** Reads the WebRTC recorder's existing samples. This class cannot open a mic. */
class WebRtcPcmTap(messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val pending = AtomicBoolean(false)
    private var track: LocalAudioTrack? = null
    @Volatile private var output: EventChannel.EventSink? = null
    private var generation = 0
    private val resampler = Pcm16Resampler()
    private val buffer = ByteBuffer.allocate(3200).order(ByteOrder.LITTLE_ENDIAN)
    private val sink = object : AudioTrackSink {
        override fun onData(data: ByteBuffer, bits: Int, rate: Int, channels: Int, frames: Int, timestamp: Long) {
            if (output == null || bits != 16 || channels < 1 || rate < 16000) return
            val samples = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            resampler.convert(samples, rate, channels) { sample ->
                buffer.putShort(sample)
                if (!buffer.hasRemaining()) {
                    val bytes = buffer.array().copyOf()
                    buffer.clear()
                    if (pending.compareAndSet(false, true)) {
                        val current = generation
                        main.post {
                            if (generation == current) output?.success(bytes)
                            pending.set(false)
                        }
                    }
                }
            }
        }
    }
    init { EventChannel(messenger, "com.wiantribe.home_listen/webrtc_pcm").setStreamHandler(this) }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        val id = (arguments as? Map<*, *>)?.get("trackId") as? String
        val local = FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(id) as? LocalAudioTrack
        if (local == null) {
            events.error("pcm_track_missing", "The WebRTC microphone track could not be observed.", null)
            return
        }
        resampler.reset()
        buffer.clear()
        output = events
        track = local
        local.addSink(sink)
    }
    override fun onCancel(arguments: Any?) {
        output = null
        track?.removeSink(sink)
        track = null
        generation++
    }
}
