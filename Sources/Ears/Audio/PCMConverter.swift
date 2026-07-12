import AVFoundation

/// Converts whatever a capture tap delivers (any rate/channels/format) into
/// 16 kHz mono Int16 little-endian PCM — Deepgram's linear16 wire format.
final class PCMConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let format = buffer.format
        if converter == nil || inputFormat != format {
            converter = AVAudioConverter(from: format, to: Self.targetFormat)
            inputFormat = format
        }
        guard let converter, buffer.frameLength > 0 else { return nil }

        let ratio = Self.targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else {
            return nil
        }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
