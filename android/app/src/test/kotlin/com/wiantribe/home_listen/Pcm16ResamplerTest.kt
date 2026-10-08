package com.wiantribe.home_listen

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Test

class Pcm16ResamplerTest {
    private fun bytes(values: List<Short>): ByteBuffer {
        val buffer = ByteBuffer.allocate(values.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        values.forEach { buffer.putShort(it) }
        buffer.flip()
        return buffer
    }
    @Test fun mono16kKeepsSampleSigns() {
        val output = mutableListOf<Short>()
        Pcm16Resampler().convert(bytes(listOf(-32768, 0, 32767)), 16000, 1) { output.add(it) }
        assertEquals(listOf<Short>(-32768, 0, 32767), output)
    }
    @Test fun stereo48kDownmixesAndFilters() {
        val output = mutableListOf<Short>()
        Pcm16Resampler().convert(bytes(listOf(600, -300, 600, -300, 600, -300)), 48000, 2) { output.add(it) }
        assertEquals(listOf<Short>(150), output)
    }
    @Test fun fractionalRateCarriesAcrossChunksWithoutDrift() {
        val resampler = Pcm16Resampler()
        var count = 0
        repeat(100) { resampler.convert(bytes(List(441) { 1200 }), 44100, 1) {
            assertEquals(1200.toShort(), it); count++
        } }
        assertEquals(16000, count)
    }
}
