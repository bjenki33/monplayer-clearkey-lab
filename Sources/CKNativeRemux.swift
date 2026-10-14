import Foundation
import Libavcodec
import Libavformat
import Libavutil

private final class CKRemuxGate {
    weak var worker: CKNativeRemux?
    let generation: Int
    init(worker: CKNativeRemux, generation: Int) { self.worker = worker; self.generation = generation }
    var interrupted: Bool { worker?.interrupted(generation) ?? true }
}

final class CKNativeRemux {
    let store: CKNativeStore
    private let condition = NSCondition()
    private var source: CKResolvedSource
    private let headers: [String: String]
    private var generation = 0, stopped = false, wantsPlaying = false
    private var didFinish = false
    // Accessed only by the serial remux worker,not the key-refresh task.
    private var timeline: CKNativeStartup.Timeline?
    private var publishedBoundary: Int64?
    var finished: Bool { condition.lock(); defer { condition.unlock() }; return didFinish }
    init(source: CKResolvedSource, headers: [String: String], store: CKNativeStore) {
        self.source = source; self.headers = headers; self.store = store
    }
    func start() {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.condition.lock(); self.didFinish = true; self.condition.broadcast(); self.condition.unlock() }
            while true {
                self.condition.lock()
                let stopped = self.stopped, source = self.source, generation = self.generation
                self.condition.unlock()
                if stopped { return }
                do { if try self.remux(source, generation: generation) { return } }
                catch {
                    if self.interrupted(generation) { continue }
                    self.store.close(failure: true)
                    CKDiagnostic.trace("native remux failed; no custom playback screen opened")
                    return
                }
                if !self.interrupted(generation) { self.store.close(failure: true); return }
            }
        }
    }
    func playing(_ value: Bool) {
        condition.lock(); wantsPlaying = value; condition.broadcast(); condition.unlock()
    }
    var paused: Bool { condition.lock(); defer { condition.unlock() }; return !wantsPlaying }
    func update(_ value: CKResolvedSource) {
        condition.lock(); source = value; generation += 1; condition.broadcast(); condition.unlock()
    }
    func stop() { condition.lock(); stopped = true; condition.broadcast(); condition.unlock() }
    fileprivate func interrupted(_ expected: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }; return stopped || generation != expected
    }
    private func waitWhilePaused(_ expected: Int) {
        condition.lock(); defer { condition.unlock() }
        while !stopped && generation == expected && !wantsPlaying && store.ready {
            condition.wait(until: Date(timeIntervalSinceNow: 1))
        }
    }
    private func remux(_ source: CKResolvedSource, generation: Int) throws -> Bool {
        let nextTimeline = CKNativeStartup.timeline(source.data)
        let resumeAfter = generation > 0 && nextTimeline != nil && timeline == nextTimeline ? publishedBoundary : nil
        if timeline != nextTimeline { publishedBoundary = nil }
        timeline = nextTimeline
        let gate = CKRemuxGate(worker: self, generation: generation)
        let opaque = Unmanaged.passRetained(gate).toOpaque()
        defer { Unmanaged<CKRemuxGate>.fromOpaque(opaque).release() }
        var input = avformat_alloc_context(), options: OpaquePointer?
        guard let inputContext = input else { throw CKNativeFailure.transport }
        inputContext.pointee.interrupt_callback.opaque = opaque
        inputContext.pointee.interrupt_callback.callback = { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<CKRemuxGate>.fromOpaque(pointer).takeUnretainedValue().interrupted ? 1 : 0
        }
        defer { avformat_close_input(&input); av_dict_free(&options) }
        let selection = CKDASHSelection.plan(source.data)
        var values = source.keys.formatOptions
        // Native HLS starts three target durations behind its published edge.
        // Prime its window from already-published input rather than future media.
        values.merge(["rw_timeout": "20000000", "tls_verify": "1", "ck_live_delay": String(CKNativeStartup.liveDelay(source.data)),
                      "ck_fragment_retry": "1", "ck_fragment_resume": "1",
                      "protocol_whitelist": "http,https,tcp,tls,crypto,httpproxy"]) { _, new in new }
        if let selection { values["ck_video_representation"] = selection.id }
        if !headers.isEmpty { values["headers"] = headers.keys.sorted().map { "\($0): \(headers[$0]!)\r\n" }.joined() }
        values.forEach { av_dict_set(&options, $0.key, $0.value, 0) }
        av_log_set_callback { pointer, level, format, arguments in
            guard level <= av_log_get_level(), let format, let arguments else { return }
            av_log_default_callback(pointer, level, format, arguments)
        }
        av_log_set_level(AV_LOG_QUIET)
        try check(avformat_open_input(&input, source.url.absoluteString, nil, &options))
        guard let context = input, context.pointee.nb_streams > 0, context.pointee.nb_streams <= 32 else { throw CKNativeFailure.transport }
        let video = av_find_best_stream(context, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        let audio = av_find_best_stream(context, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard video >= 0 else { throw CKNativeFailure.unsupportedCodec }
        let chosen = [video] + (audio >= 0 ? [audio] : [])
        guard let streams = context.pointee.streams else { throw CKNativeFailure.transport }
        if chosen.contains(where: { index in
            guard let parameters = streams[Int(index)]?.pointee.codecpar else { return true }
            return parameters.pointee.extradata_size == 0
        }) { try check(avformat_find_stream_info(context, nil)) }
        guard let videoStream = streams[Int(video)], let videoParameters = videoStream.pointee.codecpar,
              [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC].contains(videoParameters.pointee.codec_id) else { throw CKNativeFailure.unsupportedCodec }
        if audio >= 0 {
            guard let parameters = streams[Int(audio)]?.pointee.codecpar,
                  [AV_CODEC_ID_AAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_MP3].contains(parameters.pointee.codec_id) else {
                throw CKNativeFailure.unsupportedCodec
            }
        }
        let audioParameters = audio >= 0 ? streams[Int(audio)]?.pointee.codecpar : nil
        let declared = selection?.bandwidth ?? videoParameters.pointee.bit_rate
        let videoRate = max(0, min(1_000_000_000, declared))
        let audioRate = max(0, min(1_000_000_000, audioParameters?.pointee.bit_rate ?? 0))
        let total = min(1_000_000_000, videoRate + audioRate)
        var codecs: String?
        if videoParameters.pointee.codec_id == AV_CODEC_ID_H264,
           videoParameters.pointee.extradata_size >= 4, let bytes = videoParameters.pointee.extradata, bytes[0] == 1 {
            codecs = String(format: "avc1.%02x%02x%02x", bytes[1], bytes[2], bytes[3])
            if let audioParameters {
                if audioParameters.pointee.codec_id == AV_CODEC_ID_AAC,
                   audioParameters.pointee.extradata_size >= 2, let bytes = audioParameters.pointee.extradata {
                    let object = bytes[0] >> 3
                    if object > 0, object < 31 { codecs! += ",mp4a.40.\(object)" } else { codecs = nil }
                } else if audioParameters.pointee.codec_id == AV_CODEC_ID_AC3 { codecs! += ",ac-3" }
                else if audioParameters.pointee.codec_id == AV_CODEC_ID_EAC3 { codecs! += ",ec-3" }
                else if audioParameters.pointee.codec_id == AV_CODEC_ID_MP3 { codecs! += ",mp4a.6B" }
                else { codecs = nil }
            }
        }
        store.describe(bandwidth: total > 0 ? total : 4_000_000, codecs: codecs)
        var output: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&output, nil, "mp4", nil))
        guard let out = output else { throw CKNativeFailure.transport }
        defer {
            if out.pointee.pb != nil { var bytes: UnsafeMutablePointer<UInt8>?; _ = avio_close_dyn_buf(out.pointee.pb, &bytes); av_free(bytes); out.pointee.pb = nil }
            avformat_free_context(out)
        }
        var mapping: [Int32: Int32] = [:]
        for index in chosen {
            guard let sourceStream = streams[Int(index)], let parameters = sourceStream.pointee.codecpar,
                  let target = avformat_new_stream(out, nil), let targetParameters = target.pointee.codecpar else { throw CKNativeFailure.transport }
            try check(avcodec_parameters_copy(targetParameters, parameters))
            targetParameters.pointee.codec_tag = parameters.pointee.codec_id == AV_CODEC_ID_HEVC ? 0x31637668 : 0
            target.pointee.time_base = sourceStream.pointee.time_base
            target.pointee.avg_frame_rate = sourceStream.pointee.avg_frame_rate
            if index == video, let rate = selection?.frameRate {
                let probed = av_q2d(sourceStream.pointee.avg_frame_rate)
                if !probed.isFinite || probed <= 0 || probed > Double(max(240, rate * 4)) {
                    target.pointee.avg_frame_rate = av_d2q(Double(rate), 100_000)
                }
            }
            av_dict_copy(&target.pointee.metadata, sourceStream.pointee.metadata, 0)
            mapping[index] = target.pointee.index
        }
        var muxOptions: OpaquePointer?
        defer { av_dict_free(&muxOptions) }
        av_dict_set(&muxOptions, "movflags", "+empty_moov+frag_custom+default_base_moof+negative_cts_offsets+skip_sidx+skip_trailer", 0)
        try check(avio_open_dyn_buf(&out.pointee.pb))
        try check(avformat_write_header(out, &muxOptions))
        let initialization = try drain(out)
        let initName = try store.initialize(initialization, generation: generation)
        try check(avio_open_dyn_buf(&out.pointee.pb))
        var packet = av_packet_alloc()
        guard let p = packet else { throw CKNativeFailure.transport }
        defer { av_packet_free(&packet) }
        var origin: Int64?, segmentStart = Double(0), end = Double(0), hasVideo = false, firstSegment = true
        let microseconds = AVRational(num: 1, den: 1_000_000)
        while !interrupted(generation) {
            waitWhilePaused(generation)
            if interrupted(generation) { return false }
            while store.ready && store.ahead >= 7 && !interrupted(generation) { store.waitForDemand() }
            if interrupted(generation) { return false }
            let result = av_read_frame(context, p)
            if result < 0 {
                if interrupted(generation) { return false }
                // FFmpeg6.1 AVERROR_EOF; publish the real finite tail,not a fake duration.
                if result == -541478725 {
                    if hasVideo && end > segmentStart {
                        try check(av_write_frame(out, nil))
                        try store.append(drain(out), seconds: end - segmentStart, initName: initName,
                                         discontinuity: generation > 0 && firstSegment)
                    }
                    store.finish(); return true
                }
                throw CKNativeFailure.mux(result)
            }
            defer { av_packet_unref(p) }
            let index = p.pointee.stream_index
            guard let targetIndex = mapping[index], let sourceStream = streams[Int(index)],
                  let targetStream = out.pointee.streams?[Int(targetIndex)] else { continue }
            let timestamp = p.pointee.dts != Int64.min ? p.pointee.dts : p.pointee.pts
            guard timestamp != Int64.min else { throw CKNativeFailure.transport }
            let micros = av_rescale_q(timestamp, sourceStream.pointee.time_base, microseconds)
            let keyframe = index == video && p.pointee.flags & AV_PKT_FLAG_KEY != 0
            if origin == nil {
                // Reopening the same DASH epoch after key refresh must not
                // append already-published historical frames a second time.
                if let resumeAfter, micros < resumeAfter {
                    store.droppedReplay(video: index == video); continue
                }
                guard keyframe else { continue }
                origin = micros
            }
            guard let origin, micros >= origin else { continue }
            let seconds = Double(micros - origin) / 1_000_000
            if keyframe, hasVideo, seconds - segmentStart >= 1.8 {
                try check(av_write_frame(out, nil))
                try store.append(drain(out), seconds: seconds - segmentStart, initName: initName,
                                 discontinuity: generation > 0 && firstSegment)
                publishedBoundary = micros
                firstSegment = false; segmentStart = seconds; hasVideo = false
                try check(avio_open_dyn_buf(&out.pointee.pb))
            }
            let offset = av_rescale_q(origin, microseconds, sourceStream.pointee.time_base)
            if p.pointee.pts != Int64.min { p.pointee.pts -= offset }
            if p.pointee.dts != Int64.min { p.pointee.dts -= offset }
            if index == video, let rate = selection?.frameRate {
                let probed = av_q2d(sourceStream.pointee.avg_frame_rate)
                if !probed.isFinite || probed <= 0 || probed > Double(max(240, rate * 4)) {
                    p.pointee.duration = av_rescale_q(1, av_inv_q(av_d2q(Double(rate), 100_000)), sourceStream.pointee.time_base)
                    targetStream.pointee.avg_frame_rate = av_d2q(Double(rate), 100_000)
                }
            }
            av_packet_rescale_ts(p, sourceStream.pointee.time_base, targetStream.pointee.time_base)
            p.pointee.stream_index = targetIndex; p.pointee.pos = -1
            try check(av_write_frame(out, p))
            store.packet(video: index == video)
            if index == video { hasVideo = true; end = max(end, seconds + 0.04) }
            if let io = out.pointee.pb, io.pointee.pos > Int64(CKNativeStore.segmentLimit) { throw CKNativeFailure.tooLarge }
            if end - segmentStart > 12 { throw CKNativeFailure.transport }
        }
        return false
    }
    private func drain(_ context: UnsafeMutablePointer<AVFormatContext>) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        avio_flush(context.pointee.pb)
        let length = avio_close_dyn_buf(context.pointee.pb, &bytes); context.pointee.pb = nil
        defer { av_free(bytes) }
        guard length > 0, Int(length) <= CKNativeStore.segmentLimit, let bytes else { throw CKNativeFailure.tooLarge }
        return Data(bytes: bytes, count: Int(length))
    }
    private func check(_ code: Int32) throws { if code < 0 { throw CKNativeFailure.mux(code) } }
}
