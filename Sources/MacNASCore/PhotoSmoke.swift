import Foundation
import Vision
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public struct PhotoSmokeReport: Codable {
    public var evidenceClass: String = "LOCAL_MAC_OBSERVATION_SYNTHETIC_ONLY"
    public var featurePrintRevision: Int
    public var identicalImageDistance: Float
    public var supportedOCRLanguages: [String]
    public var recognized: [String]
    public var recognizedByLanguage: [String: [String]]
    public var exactLanguageMatches: [String: Bool]
    public var groundTruth: [String] = ["MacNAS 2026", "中文测试", "日本語テスト"]
    public var faceGrouping: String = "NOT_IMPLEMENTED"
    public var naturalLanguageImageRetrieval: String = "BLOCKED_NO_VALIDATED_APPLE_ONLY_PIPELINE"
}
public enum PhotoSmoke {
    public static func run(outputDirectory: URL) throws -> PhotoSmokeReport {
        try SafeFS.freshDirectory(outputDirectory)
        guard let ctx = CGContext(data: nil, width: 1400, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw NASError.unsupported }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 700))
        let lines = ["MacNAS 2026", "中文测试", "日本語テスト"]
        for (index, text) in lines.enumerated() {
            let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 86, nil)
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                  NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 90, y: 530 - index * 170)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        guard let image = ctx.makeImage() else { throw NASError.unsupported }
        let imageURL = try SafeFS.resolve(outputDirectory, "synthetic-ocr.png")
        guard let dest = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NASError.unsupported }
        CGImageDestinationAddImage(dest, image, nil)
        try require(CGImageDestinationFinalize(dest), .integrity)
        func printForImage() throws -> VNFeaturePrintObservation {
            let request = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else { throw NASError.unsupported }
            return observation
        }
        let first = try printForImage(), second = try printForImage()
        var distance: Float = -1
        try first.computeDistance(&distance, to: second)
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        let supported = try ocr.supportedRecognitionLanguages()
        ocr.recognitionLanguages = ["en-US", "zh-Hans", "ja-JP"].filter { supported.contains($0) }
        ocr.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([ocr])
        let recognized = ocr.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        var perLanguage: [String: [String]] = [:]
        var exactMatches: [String: Bool] = [:]
        for (index, language) in ["en-US", "zh-Hans", "ja-JP"].enumerated() where supported.contains(language) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = [language]
            request.usesLanguageCorrection = false
            request.regionOfInterest = CGRect(x:0.03, y:Double(510-index*170)/700, width:0.94, height:0.2)
            try VNImageRequestHandler(cgImage:image).perform([request])
            let values = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            perLanguage[language] = values; exactMatches[language] = values.contains(lines[index])
        }
        let report = PhotoSmokeReport(featurePrintRevision: first.requestRevision, identicalImageDistance: distance,
                                      supportedOCRLanguages: supported, recognized: recognized, recognizedByLanguage: perLanguage, exactLanguageMatches: exactMatches)
        try SafeFS.write(report, to: SafeFS.resolve(outputDirectory, "report.json"))
        return report
    }
}
