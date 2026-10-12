import Foundation
import Testing
@testable import MagicWineCore

struct DownloadProgressTests {
    @Test(arguments: [Int64.min, -1, 0])
    func nonpositiveLengthIsUnknown(total: Int64) {
        let progress = WineDownloadProgress(receivedBytes: 512, totalBytes: total, bytesPerSecond: 128)
        #expect(progress.receivedBytes == 512)
        #expect(progress.totalBytes == nil)
        #expect(progress.fractionCompleted == nil)
        #expect(progress.bytesPerSecond == 128)
    }

    @Test func normalizesSizeAndFraction() {
        let negative = WineDownloadProgress(receivedBytes: -10, totalBytes: 100)
        #expect(negative.receivedBytes == 0)
        #expect(negative.fractionCompleted == 0)
        #expect(WineDownloadProgress(receivedBytes: 25, totalBytes: 100).fractionCompleted == 0.25)
        #expect(WineDownloadProgress(receivedBytes: 150, totalBytes: 100).fractionCompleted == 1)
        #expect(WineDownloadProgress(receivedBytes: Int64.max, totalBytes: 1).fractionCompleted == 1)
        #expect(WineDownloadProgress(receivedBytes: Int64.max, totalBytes: Int64.max).fractionCompleted == 1)
        #expect(WineDownloadProgress(receivedBytes: 100).fractionCompleted == nil)
    }

    @Test func rejectsInvalidSpeed() {
        for speed in [-1.0, -Double.infinity, Double.infinity, Double.nan] {
            let progress = WineDownloadProgress(receivedBytes: 1, bytesPerSecond: speed)
            #expect(progress.bytesPerSecond == 0)
            #expect(progress.bytesPerSecond.isFinite)
        }
        #expect(WineDownloadProgress(receivedBytes: 1, bytesPerSecond: 12.5).bytesPerSecond == 12.5)
    }

    @Test func throttlesIntermediateSamplesToFourPerSecond() throws {
        var sampler = DownloadProgressSampler(now: 0)
        let initialSample = sampler.record(receivedBytes: 0, totalBytes: nil, now: 0)
        let initial = try #require(initialSample)
        #expect(initial.bytesPerSecond == 0)
        var emissions: [(TimeInterval, WineDownloadProgress)] = []
        for tick in 1...100 {
            let now = Double(tick) / 100
            if let sample = sampler.record(receivedBytes: Int64(tick * 10), totalBytes: 1_000, now: now) {
                emissions.append((now, sample))
            }
        }
        #expect(emissions.count == 4)
        var previousTime: TimeInterval = 0
        var previousBytes: Int64 = 0
        for (time, sample) in emissions {
            #expect(time - previousTime >= 0.25)
            #expect(sample.receivedBytes > previousBytes)
            #expect(sample.totalBytes == 1_000)
            #expect(abs(sample.bytesPerSecond - 1_000) < 0.001)
            previousTime = time
            previousBytes = sample.receivedBytes
        }
    }

    @Test func measuresRecentIntervalRatherThanDownloadAverage() throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: 1_000, now: 0)
        let firstSample = sampler.record(receivedBytes: 250, totalBytes: 1_000, now: 0.25)
        let first = try #require(firstSample)
        #expect(first.bytesPerSecond == 1_000)
        let secondSample = sampler.record(receivedBytes: 750, totalBytes: 1_000, now: 0.5)
        let second = try #require(secondSample)
        #expect(second.bytesPerSecond == 2_000)
        #expect(second.fractionCompleted == 0.75)
    }

    @Test(arguments: [0.0, 0.000_001])
    func zeroOrTinyElapsedTimeHasFiniteSpeed(elapsed: TimeInterval) throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: 100, now: 0)
        let finalSample = sampler.record(receivedBytes: 100, totalBytes: 100, now: elapsed, finished: true)
        let final = try #require(finalSample)
        #expect(final.receivedBytes == 100)
        #expect(final.fractionCompleted == 1)
        #expect(final.bytesPerSecond == 0)
        #expect(final.bytesPerSecond.isFinite)
    }

    @Test func measuresUnknownLengthWithoutInventingCompletionFraction() throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: -1, now: 0)
        let transferSample = sampler.record(receivedBytes: 125, totalBytes: -1, now: 0.25)
        let transfer = try #require(transferSample)
        #expect(transfer.totalBytes == nil)
        #expect(transfer.fractionCompleted == nil)
        #expect(transfer.bytesPerSecond == 500)
        let finalSample = sampler.record(receivedBytes: 200, totalBytes: -1, now: 0.5, finished: true)
        let final = try #require(finalSample)
        #expect(final.receivedBytes == 200)
        #expect(final.fractionCompleted == nil)
        #expect(final.bytesPerSecond == 300)
    }

    @Test func measuresSlowTransfersAcrossLongNotificationIntervals() throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: 1_000, now: 0)
        let firstSample = sampler.record(receivedBytes: 250, totalBytes: 1_000, now: 0.25)
        let first = try #require(firstSample)
        #expect(first.bytesPerSecond == 1_000)
        let resumedSample = sampler.record(receivedBytes: 500, totalBytes: 1_000, now: 5.25)
        let resumed = try #require(resumedSample)
        #expect(resumed.bytesPerSecond == 50)
        let nextSample = sampler.record(receivedBytes: 750, totalBytes: 1_000, now: 5.5)
        let next = try #require(nextSample)
        #expect(next.bytesPerSecond == 1_000)
    }

    @Test func forcesFinalEmissionInsideThrottleWindowExactlyOnce() throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: 300, now: 0)
        _ = sampler.record(receivedBytes: 250, totalBytes: 300, now: 0.25)
        #expect(sampler.record(receivedBytes: 275, totalBytes: 300, now: 0.26) == nil)
        let finalSample = sampler.record(receivedBytes: 300, totalBytes: 300, now: 0.27, finished: true)
        let final = try #require(finalSample)
        #expect(final.receivedBytes == 300)
        #expect(final.fractionCompleted == 1)
        #expect(final.bytesPerSecond.isFinite)
        #expect(final.bytesPerSecond > 0)
        #expect(sampler.record(receivedBytes: 300, totalBytes: 300, now: 0.5, finished: true) == nil)
        #expect(sampler.record(receivedBytes: 350, totalBytes: 300, now: 1) == nil)
    }

    @Test func keepsReceivedBytesMonotonic() throws {
        var sampler = DownloadProgressSampler(now: 0)
        _ = sampler.record(receivedBytes: 0, totalBytes: 1_000, now: 0)
        _ = sampler.record(receivedBytes: 500, totalBytes: 1_000, now: 0.5)
        let lowerSample = sampler.record(receivedBytes: 400, totalBytes: 1_000, now: 0.75)
        let lower = try #require(lowerSample)
        #expect(lower.receivedBytes == 500)
        #expect(lower.bytesPerSecond == 0)
        let resumedSample = sampler.record(receivedBytes: 600, totalBytes: 1_000, now: 1)
        let resumed = try #require(resumedSample)
        #expect(resumed.receivedBytes == 600)
        #expect(resumed.bytesPerSecond == 400)
    }
}
