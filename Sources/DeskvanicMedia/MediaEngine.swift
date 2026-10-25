import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import DeskvanicCore
import UniformTypeIdentifiers

/// Media Studio 引擎：音视频裁剪、音频提取、格式转换、GIF 生成（AVFoundation）。
/// 能力边界（如实声明）：只支持系统编解码器覆盖的格式；
/// 不承诺"无损转换所有音视频格式"——转码均为有损重编码（除非容器转换保留码流）。
public enum MediaEngine {

    // MARK: - 探测

    public struct MediaInfo: Sendable {
        public let durationSeconds: Double
        public let hasVideo: Bool
        public let hasAudio: Bool
        public let naturalSize: CGSize?
        public let format: String
    }

    public static func inspect(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size: CGSize?
        if let videoTrack = videoTracks.first {
            size = try? await videoTrack.load(.naturalSize)
        } else {
            size = nil
        }
        return MediaInfo(
            durationSeconds: CMTimeGetSeconds(duration),
            hasVideo: !videoTracks.isEmpty,
            hasAudio: !audioTracks.isEmpty,
            naturalSize: size,
            format: url.pathExtension.lowercased())
    }

    // MARK: - 裁剪（音频/视频通用）

    /// 按时间范围裁剪并导出。输出格式按源文件容器保持（mp4→mp4, m4a→m4a, mov→mov）。
    public static func trim(
        source: URL, start seconds: Double, end secondsEnd: Double,
        destinationDirectory: URL
    ) async throws -> URL {
        guard secondsEnd > seconds, seconds >= 0 else {
            throw DeskvanicError(.invalidInput, "时间范围无效：\(seconds) – \(secondsEnd)")
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let total = CMTimeGetSeconds(duration)
        guard secondsEnd <= total + 0.5 else {
            throw DeskvanicError(.invalidInput, "结束时间超出时长（\(String(format: "%.1f", total))s）")
        }
        let isVideo = try await asset.loadTracks(withMediaType: .video).isEmpty == false
        let exportExtension = isVideo ? "mp4" : "m4a"
        let output = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension)
                + "-trim.\(exportExtension)")

        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: isVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A) else {
            throw DeskvanicError(.externalService, "无法创建导出会话")
        }
        export.outputURL = output
        export.outputFileType = isVideo ? .mp4 : .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: seconds, preferredTimescale: 600),
            end: CMTime(seconds: secondsEnd, preferredTimescale: 600))
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.externalService, "导出失败：\(export.error?.localizedDescription ?? "未知")")
        }
        try await verifyOutput(url: output, minDuration: (secondsEnd - seconds) * 0.8)
        return output
    }

    // MARK: - 音频提取

    /// 从视频提取音频轨（m4a）。
    public static func extractAudio(source: URL, destinationDirectory: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await asset.loadTracks(withMediaType: .audio).isEmpty == false else {
            throw DeskvanicError(.unsupportedFormat, "源文件没有音频轨")
        }
        let output = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension) + "-audio.m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DeskvanicError(.externalService, "无法创建导出会话")
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.externalService, "音频提取失败：\(export.error?.localizedDescription ?? "未知")")
        }
        try await verifyOutput(url: output, minDuration: 0.1)
        return output
    }

    // MARK: - 音频格式转换

    /// 音频转码（wav/m4a/aiff）。采样率与声道保持源设定。
    public static func convertAudio(
        source: URL, to format: AudioFormat, destinationDirectory: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await asset.loadTracks(withMediaType: .audio).isEmpty == false else {
            throw DeskvanicError(.unsupportedFormat, "源文件没有音频轨")
        }
        let output = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension)
                + "." + format.fileExtension)
        switch format {
        case .wav, .aiff:
            // PCM 容器：AVAssetWriter 逐帧转码
            try await transcodeToPCM(asset: asset, output: output, format: format)
        case .m4a:
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw DeskvanicError(.externalService, "无法创建导出会话")
            }
            export.outputURL = output
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw DeskvanicError(.externalService, "转换失败：\(export.error?.localizedDescription ?? "未知")")
            }
        }
        try await verifyOutput(url: output, minDuration: 0.1)
        return output
    }

    public enum AudioFormat: String, CaseIterable, Sendable {
        case wav, m4a, aiff

        public var fileExtension: String { rawValue }
    }

    private static func transcodeToPCM(asset: AVURLAsset, output: URL, format: AudioFormat) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else {
            throw DeskvanicError(.unsupportedFormat, "没有音频轨")
        }
        let timeBase = try await asset.load(.duration)
        let sampleRate = (try? await track.load(.nominalFrameRate)) ?? 44100
        let channelCount = 2
        var settings: [String: Any] = [
            AVFormatIDKey: format == .wav ? kAudioFormatLinearPCM : kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
        ]
        _ = settings
        let writer = try AVAssetWriter(outputURL: output, fileType: format == .aiff ? .aiff : .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(readerOutput)
        reader.startReading()
        await writer.inputs.first?.requestMediaDataWhenReady(
            on: .global(qos: .utility)) {
            while writer.inputs.first?.isReadyForMoreMediaData == true {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    writer.inputs.first?.append(sample)
                } else {
                    writer.inputs.first?.markAsFinished()
                    break
                }
            }
        }
        while reader.status == .reading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.externalService, "PCM 转码失败（\(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "未知")）")
        }
        _ = timeBase
    }

    // MARK: - GIF 生成

    /// 视频片段转 GIF：按帧率采样 + 调色板量化（ImageIO）。
    public static func generateGIF(
        source: URL, start seconds: Double, duration: Double,
        framesPerSecond: Int = 8, maxPixel: Int = 480,
        destinationDirectory: URL
    ) async throws -> URL {
        guard (1...20).contains(framesPerSecond) else {
            throw DeskvanicError(.invalidInput, "帧率必须在 1...20")
        }
        guard (8...5120).contains(maxPixel) else {
            throw DeskvanicError(.invalidInput, "GIF 最大边长必须在 8...5120")
        }
        guard duration > 0, duration <= 60 else {
            throw DeskvanicError(.invalidInput, "GIF 时长必须在 0–60 秒内")
        }
        let asset = AVURLAsset(url: source)
        let total = CMTimeGetSeconds(try await asset.load(.duration))
        guard seconds + duration <= total + 0.5 else {
            throw DeskvanicError(.invalidInput, "时间范围超出视频时长")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let frameCount = Int(duration * Double(framesPerSecond))
        let output = FileSafety.uniqueDestination(
            in: destinationDirectory,
            preferredName: ((source.lastPathComponent as NSString).deletingPathExtension) + ".gif")

        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw DeskvanicError(.fileWriteFailed, "无法创建 GIF 输出")
        }
        let frameDelay = 1.0 / Double(framesPerSecond)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
            ],
        ]
        var written = 0
        for index in 0..<frameCount {
            let time = CMTime(seconds: seconds + Double(index) * frameDelay, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image {
                CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
                written += 1
            }
        }
        guard written > 0 else {
            throw DeskvanicError(.outputValidationFailed, "没有成功采样任何帧")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,  // 无限循环
            ],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw DeskvanicError(.fileWriteFailed, "GIF 编码失败")
        }
        try FileSafety.validateOutput(at: output)
        return output
    }

    // MARK: - 波形数据（UI 用）

    /// 读取音频生成波形柱（barCount 个 0...1 振幅）。
    public static func waveform(url: URL, barCount: Int = 120) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0, barCount > 0 else { return [] }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(totalFrames, 1 << 20)) else {
            return []
        }
        var peaks = [Double](repeating: 0, count: barCount)
        var readFrame = AVAudioFramePosition(0)
        let framesPerBar = max(1, Int(totalFrames) / barCount)
        var barIndex = 0
        var barPeak: Float = 0
        var framesInBar = 0
        while readFrame < AVAudioFramePosition(file.length) && barIndex < barCount {
            let toRead = AVAudioFrameCount(min(1 << 20, AVAudioFramePosition(file.length) - readFrame))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: toRead)
            guard let channel = buffer.floatChannelData?[0] else { break }
            for i in 0..<Int(buffer.frameLength) {
                let sample = abs(channel[i])
                if sample > barPeak { barPeak = sample }
                framesInBar += 1
                if framesInBar >= framesPerBar {
                    peaks[min(barIndex, barCount - 1)] = Double(barPeak)
                    barIndex += 1
                    barPeak = 0
                    framesInBar = 0
                    if barIndex >= barCount { break }
                }
            }
            readFrame += AVAudioFramePosition(buffer.frameLength)
        }
        let maxValue = peaks.max() ?? 1
        if maxValue > 0 {
            peaks = peaks.map { $0 / maxValue }
        }
        return peaks
    }

    // MARK: - 输出校验

    private static func verifyOutput(url: URL, minDuration: Double) async throws {
        try FileSafety.validateOutput(at: url)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else {
            try? FileManager.default.removeItem(at: url)
            throw DeskvanicError(.outputValidationFailed, "输出无法解码，已清理")
        }
        guard CMTimeGetSeconds(duration) >= minDuration else {
            try? FileManager.default.removeItem(at: url)
            throw DeskvanicError(.outputValidationFailed, "输出时长异常（\(CMTimeGetSeconds(duration))s < \(minDuration)s），已清理")
        }
    }
}
