package com.wiantribe.home_listen

import java.nio.ByteBuffer

/** Streaming downmix and box-filter resampling to the classifier's 16 kHz. */
class Pcm16Resampler {
    private var phase = 0
    private var sum = 0L
    private var count = 0
    private var previousRate = 0
    fun reset() { phase = 0; sum = 0; count = 0; previousRate = 0 }
    fun convert(data: ByteBuffer, rate: Int, channels: Int, emit: (Short) -> Unit) {
        require(rate >= 16000 && channels in 1..8)
        if (rate != previousRate) { reset(); previousRate = rate }
        while (data.remaining() >= channels * 2) {
            var mono = 0
            repeat(channels) { mono += data.short.toInt() }
            sum += mono / channels
            count++
            phase += 16000
            if (phase >= rate) {
                emit((sum / count).toShort())
                phase -= rate
                sum = 0
                count = 0
            }
        }
    }
}
