import AVFoundation
import Foundation

public struct PCMAudio: Sendable, Equatable {
    public static let sampleRate: Double = 16_000

    public var samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var duration: TimeInterval {
        Double(samples.count) / Self.sampleRate
    }
}

public enum WAVFile {
    public static func write(_ audio: PCMAudio, to url: URL) throws {
        try write(audio.samples[...], to: url)
    }

    static func write(_ samples: ArraySlice<Float>, to url: URL) throws {
        let dataSize = UInt32(samples.count * 2)
        let rate = UInt32(PCMAudio.sampleRate)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append(Int16((clamped * Float(Int16.max)).rounded()))
        }
        try data.write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) throws -> PCMAudio {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path]) }
        converter.downmix = true

        let inputCapacity: AVAudioFrameCount = 32_768
        let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * PCMAudio.sampleRate / inputFormat.sampleRate) + 1024
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * PCMAudio.sampleRate / inputFormat.sampleRate) + 1024)
        var readError: Error?
        var finished = false

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if finished || file.framePosition >= file.length {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                } catch {
                    readError = error
                }
                if input.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return PCMAudio(samples: samples)
    }
}
