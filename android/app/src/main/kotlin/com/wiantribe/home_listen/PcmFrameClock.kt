package com.wiantribe.home_listen

/** Stamp capture before dispatch to the UI thread; delivery jitter is not loss. */
class PcmFrameClock {
    data class Stamp(val sequence: Long, val clockMs: Long)
    private var sequence = 0L
    private var samples = 0L
    fun next(sampleCount: Int): Stamp {
        require(sampleCount > 0)
        val stamp = Stamp(sequence and 0xffffffffL, (samples * 1000 / 16000) and 0xffffffffL)
        sequence++
        samples += sampleCount
        return stamp
    }
    fun reset() { sequence = 0; samples = 0 }
}
