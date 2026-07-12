import AVFoundation
import Testing
@testable import Ears

struct PCMConverterTests {
    private func sineBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
            }
        }
        return buffer
    }

    @Test func convertsStereo48kToExpectedMono16kByteCount() {
        let converter = PCMConverter()
        let buffer = sineBuffer(sampleRate: 48000, channels: 2, frames: 4800)  // 100 ms

        var total = 0
        // Feed several buffers; sample-rate converters hold a few frames
        // internally, so judge the aggregate.
        for _ in 0..<10 {
            if let data = converter.convert(buffer) {
                total += data.count
            }
        }

        // 1 second of input → ~1 second of 16 kHz mono Int16 = 32,000 bytes.
        #expect(abs(total - 32_000) <= 1_600)
    }

    @Test func outputIsNonSilentForNonSilentInput() throws {
        let converter = PCMConverter()
        let buffer = sineBuffer(sampleRate: 48000, channels: 1, frames: 4800)
        let data = try #require(converter.convert(buffer))
        let hasSignal = data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).contains { abs(Int($0)) > 1000 }
        }
        #expect(hasSignal)
    }

    @Test func handlesFormatChangeMidStream() {
        let converter = PCMConverter()
        let first = sineBuffer(sampleRate: 48000, channels: 2, frames: 4800)
        let second = sineBuffer(sampleRate: 44100, channels: 1, frames: 4410)

        #expect(converter.convert(first) != nil)
        #expect(converter.convert(second) != nil)
    }
}
