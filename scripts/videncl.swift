import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

// usage: videncl <fps> <out.mov> <frame.png> ...
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let fps = Int32(args[0]) else { print("usage"); exit(2) }
let outPath = args[1]
let framePaths = Array(args.dropFirst(2))

func loadPNG(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
let imgs = framePaths.compactMap(loadPNG)
guard let first = imgs.first else { print("no frames"); exit(1) }
let w = first.width, h = first.height
let out = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: out)

let writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
let settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
    AVVideoWidthKey: w,
    AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.9]
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h
    ])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func makeBuffer(_ img: CGImage) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    guard let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

for (i, img) in imgs.enumerated() {
    while !input.isReadyForMoreMediaData { usleep(800) }
    if let buf = makeBuffer(img) {
        _ = adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status == .completed {
    let size = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int) ?? 0
    print("ok \(framePaths.count) frames \(size/1024) KB -> \(outPath)")
} else {
    print("fail \(String(describing: writer.error))"); exit(1)
}
