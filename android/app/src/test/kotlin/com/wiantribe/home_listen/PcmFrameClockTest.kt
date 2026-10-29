package com.wiantribe.home_listen

import org.junit.Assert.assertEquals
import org.junit.Test

class PcmFrameClockTest {
    @Test fun captureTimeDoesNotDependOnDeliveryTime() {
        val clock = PcmFrameClock()
        val stamps = (0 until 400).map { clock.next(1600) }
        // These can be delivered late or in batches; capture cadence stays 100ms.
        stamps.forEachIndexed { index, stamp ->
            assertEquals(index.toLong(), stamp.sequence)
            assertEquals(index * 100L, stamp.clockMs)
        }
    }
    @Test fun droppedDeliveryRetainsItsGapAndRestartResetsClock() {
        val clock = PcmFrameClock()
        val first = clock.next(1600)
        clock.next(1600) // Captured but delivery queue overflowed.
        val next = clock.next(1600)
        assertEquals(2L, next.sequence - first.sequence)
        assertEquals(200L, next.clockMs - first.clockMs)
        clock.reset()
        assertEquals(PcmFrameClock.Stamp(0, 0), clock.next(1600))
    }
}
