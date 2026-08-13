import Flutter
import CoreImage
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VisionScannerPlugin") else { return }
    VisionScannerPlugin.register(with: registrar)
  }
}

private struct VisionEvidence {
  let value: String
  let source: String
  let confidence: Float
  let x: CGFloat
  let topY: CGFloat
  let box: CGRect
}

private struct VisionBatch {
  var evidence: [VisionEvidence]
  var barcodePayloads: [String]
  var rawText: String
  var barcodeBoxes: [CGRect]
}

private struct VisionGroup {
  var evidence: [VisionEvidence]
  var x: CGFloat
  var topY: CGFloat
}

final class VisionScannerPlugin: NSObject, FlutterPlugin {
  private let barcodeThreshold: Float = 0.85
  private let ocrThreshold: Float = 0.90

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "multiscan/vision_scanner", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VisionScannerPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "analyzeTray" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "An image path is required.", details: nil))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let response = try self.analyze(path: path)
        DispatchQueue.main.async { result(response) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "VISION_ERROR", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  private func analyze(path: String) throws -> [String: Any] {
    guard let uiImage = UIImage(contentsOfFile: path), let image = normalizedImage(uiImage) else {
      throw NSError(domain: "VisionScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not load the selected image."])
    }

    // A full-sheet request can miss small symbols when many barcodes are
    // visible at once. Scan overlapping tiles as well as the complete image,
    // then merge the repeated observations below.
    var passes: [VisionBatch] = [read(image, rotated: false), readTiled(image, rotated: false)]
    if let enhanced = enhancedImage(image) {
      passes.append(readTiled(enhanced, rotated: false))
    }
    if let rotatedImage = rotate180(image) {
      passes.append(readTiled(rotatedImage, rotated: true))
      if let enhancedRotated = enhancedImage(rotatedImage) {
        passes.append(readTiled(enhancedRotated, rotated: true))
      }
    }

    let evidence = unique(passes.flatMap(\.evidence))
    let barcodePayloads = Array(Set(passes.flatMap(\.barcodePayloads)))
    let allText = passes.map(\.rawText).filter { !$0.isEmpty }.joined(separator: "\n")
    let barcodeBoxes = uniqueBoxes(passes.flatMap(\.barcodeBoxes))

    let groups = compactGroups(evidence)
    let positions = dynamicPositions(groups)
    var outputGroups = groups.sorted { $0.topY == $1.topY ? $0.x < $1.x : $0.topY < $1.topY }
    if outputGroups.isEmpty && !barcodePayloads.isEmpty {
      outputGroups = [VisionGroup(evidence: [], x: 0.5, topY: 0.5)]
    }
    if outputGroups.isEmpty {
      outputGroups = [VisionGroup(evidence: [], x: 0.5, topY: 0.5)]
    }

    var cells = outputGroups.enumerated().map { index, group in
      resolve(position: positions.count == outputGroups.count ? positions[index] : "P\(index + 1)", evidence: group.evidence, rawText: allText)
    }

    markDuplicates(&cells)
    return [
      "cells": cells,
      "barcodeValues": barcodePayloads,
      "barcodeBoxes": barcodeBoxes.map(boxMap),
      "rawText": allText,
      "rawBarcodeCount": passes.reduce(0) { $0 + $1.barcodePayloads.count },
      "uniqueBarcodeCount": barcodePayloads.count,
      "groupCount": groups.count,
      "processingVersion": "ios-vision-tiled-v4",
    ]
  }

  private func read(_ image: CGImage, rotated: Bool) -> VisionBatch {
    let fullRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    return read(image, rotated: rotated, crop: fullRect, canvasSize: CGSize(width: image.width, height: image.height))
  }

  private func readTiled(_ image: CGImage, rotated: Bool) -> VisionBatch {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let canvasSize = CGSize(width: width, height: height)
    let columns = 3
    let rows = 4
    let overlap: CGFloat = 0.18
    var result = VisionBatch(evidence: [], barcodePayloads: [], rawText: "", barcodeBoxes: [])

    for row in 0..<rows {
      for column in 0..<columns {
        let baseX = CGFloat(column) / CGFloat(columns)
        let baseY = CGFloat(row) / CGFloat(rows)
        let baseWidth = 1 / CGFloat(columns)
        let baseHeight = 1 / CGFloat(rows)
        let crop = CGRect(
          x: max(0, (baseX - baseWidth * overlap / 2) * width),
          y: max(0, (baseY - baseHeight * overlap / 2) * height),
          width: min(width, (baseWidth * (1 + overlap)) * width),
          height: min(height, (baseHeight * (1 + overlap)) * height)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard crop.width > 20, crop.height > 20, let tile = image.cropping(to: crop) else { continue }
        let batch = read(tile, rotated: rotated, crop: crop, canvasSize: canvasSize)
        result.evidence.append(contentsOf: batch.evidence)
        result.barcodePayloads.append(contentsOf: batch.barcodePayloads)
        result.barcodeBoxes.append(contentsOf: batch.barcodeBoxes)
        if !batch.rawText.isEmpty { result.rawText += batch.rawText + "\n" }
      }
    }
    return result
  }

  private func read(_ image: CGImage, rotated: Bool, crop: CGRect, canvasSize: CGSize) -> VisionBatch {
    let barcodeRequest = VNDetectBarcodesRequest()
    barcodeRequest.symbologies = [.code128, .code39, .code93, .itf14, .ean13, .ean8, .upce]
    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .accurate
    textRequest.recognitionLanguages = ["en-US"]
    textRequest.usesLanguageCorrection = false

    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([barcodeRequest, textRequest])
    } catch {
      return VisionBatch(evidence: [], barcodePayloads: [], rawText: "", barcodeBoxes: [])
    }

    var evidence: [VisionEvidence] = []
    var payloads: [String] = []
    var barcodeBoxes: [CGRect] = []
    for observation in barcodeRequest.results ?? [] {
      guard let payload = observation.payloadStringValue else { continue }
      payloads.append(payload)
      barcodeBoxes.append(mappedRect(observation.boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize))
      let point = mappedPoint(observation.boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize)
      for value in validCandidates(payload) {
        evidence.append(VisionEvidence(value: value, source: "barcode", confidence: observation.confidence, x: point.x, topY: point.y, box: mappedRect(observation.boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize)))
      }
    }

    var lines: [String] = []
    for observation in textRequest.results ?? [] {
      guard let recognized = observation.topCandidates(1).first else { continue }
      lines.append(recognized.string)
      let point = mappedPoint(observation.boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize)
      for value in validCandidates(recognized.string) {
        evidence.append(VisionEvidence(value: value, source: "ocr", confidence: observation.confidence, x: point.x, topY: point.y, box: mappedRect(observation.boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize)))
      }
    }
    return VisionBatch(evidence: evidence, barcodePayloads: payloads, rawText: lines.joined(separator: "\n"), barcodeBoxes: barcodeBoxes)
  }

  private func compactGroups(_ evidence: [VisionEvidence]) -> [VisionGroup] {
    var groups: [VisionGroup] = []
    for item in evidence.sorted(by: { $0.topY == $1.topY ? $0.x < $1.x : $0.topY < $1.topY }) {
      if let index = groups.firstIndex(where: { group in
        group.evidence.contains { sameLabel($0.box, item.box) }
      }) {
        groups[index].evidence.append(item)
        groups[index].x = (groups[index].x + item.x) / 2
        groups[index].topY = (groups[index].topY + item.topY) / 2
      } else {
        groups.append(VisionGroup(evidence: [item], x: item.x, topY: item.topY))
      }
    }
    return groups
  }

  private func dynamicPositions(_ groups: [VisionGroup]) -> [String] {
    guard groups.count > 1 else { return groups.isEmpty ? [] : ["P1"] }
    let sorted = groups.sorted { $0.topY == $1.topY ? $0.x < $1.x : $0.topY < $1.topY }
    let heights = groups.flatMap { $0.evidence.map { $0.box.height } }.sorted()
    let medianHeight = heights.isEmpty ? 0.04 : heights[heights.count / 2]
    let rowTolerance = max(0.025, min(0.065, medianHeight * 1.35))
    var rows: [[VisionGroup]] = []
    for group in sorted {
      if let lastIndex = rows.indices.last {
        let rowY = rows[lastIndex].map(\.topY).reduce(0, +) / CGFloat(rows[lastIndex].count)
        if abs(rowY - group.topY) < rowTolerance {
          rows[lastIndex].append(group)
          continue
        }
      }
      rows.append([group])
    }
    return rows.enumerated().flatMap { rowIndex, row in
      row.sorted { $0.x < $1.x }.enumerated().map { columnIndex, _ in "R\(rowIndex + 1)C\(columnIndex + 1)" }
    }
  }

  private func resolve(position: String, evidence: [VisionEvidence], rawText: String) -> [String: Any] {
    let barcodes = unique(evidence.filter { $0.source == "barcode" })
    let ocr = unique(evidence.filter { $0.source == "ocr" })
    let barcodeValues = Set(barcodes.map(\.value))
    let ocrValues = Set(ocr.map(\.value))
    let matching = barcodeValues.intersection(ocrValues)

    if matching.count == 1, let value = matching.first {
      let confidence = max(best(barcodes, value: value), best(ocr, value: value))
      let accepted = confidence >= min(barcodeThreshold, ocrThreshold)
      return cell(position: position, status: accepted ? "accepted" : "review", source: "both", confidence: confidence, reason: accepted ? "Barcode and OCR agree" : "Barcode and OCR agree but confidence is low", imei: value, rawText: rawText, evidence: evidence)
    }
    if matching.count > 1 || barcodeValues.count > 1 || ocrValues.count > 1 {
      return cell(position: position, status: "review", source: "conflict", confidence: 0, reason: "Multiple IMEI candidates detected", imei: nil, rawText: rawText, evidence: evidence)
    }
    if let value = barcodeValues.first, ocrValues.isEmpty {
      let confidence = best(barcodes, value: value)
      return cell(position: position, status: confidence >= barcodeThreshold ? "accepted" : "review", source: "barcode", confidence: confidence, reason: confidence >= barcodeThreshold ? "Valid barcode detected" : "Barcode confidence is low", imei: value, rawText: rawText, evidence: evidence)
    }
    if let value = ocrValues.first, barcodeValues.isEmpty {
      let confidence = best(ocr, value: value)
      return cell(position: position, status: confidence >= ocrThreshold ? "accepted" : "review", source: "ocr", confidence: confidence, reason: confidence >= ocrThreshold ? "Valid OCR candidate detected" : "OCR confidence is low", imei: value, rawText: rawText, evidence: evidence)
    }
    if !barcodeValues.isEmpty || !ocrValues.isEmpty {
      return cell(position: position, status: "review", source: "conflict", confidence: 0, reason: "Barcode and OCR results conflict", imei: nil, rawText: rawText, evidence: evidence)
    }
    return cell(position: position, status: "retake", source: "none", confidence: 0, reason: "No readable IMEI in this position", imei: nil, rawText: rawText, evidence: evidence)
  }

  private func cell(position: String, status: String, source: String, confidence: Float, reason: String, imei: String?, rawText: String, evidence: [VisionEvidence]) -> [String: Any] {
    var result: [String: Any] = ["position": position, "status": status, "source": source, "confidence": Double(confidence), "reason": reason, "rawText": rawText, "boxes": evidenceBoxes(evidence)]
    if let imei { result["imei"] = imei }
    return result
  }

  private func markDuplicates(_ cells: inout [[String: Any]]) {
    var positions: [String: [Int]] = [:]
    for index in cells.indices where cells[index]["status"] as? String == "accepted" {
      if let imei = cells[index]["imei"] as? String { positions[imei, default: []].append(index) }
    }
    for (imei, indexes) in positions where indexes.count > 1 {
      for index in indexes {
        cells[index]["status"] = "review"
        cells[index]["reason"] = "Duplicate IMEI detected: \(imei)"
      }
    }
  }

  private func validCandidates(_ text: String) -> [String] {
    let compact = text.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    var values: [String] = []
    if compact.count == 15, isValidImei(compact) { values.append(compact) }
    let pattern = try! NSRegularExpression(pattern: "(?<![0-9])[0-9]{15}(?![0-9])")
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in pattern.matches(in: text, range: range) {
      if let matchRange = Range(match.range, in: text) {
        let candidate = String(text[matchRange])
        if isValidImei(candidate) { values.append(candidate) }
      }
    }
    return Array(Set(values))
  }

  private func isValidImei(_ value: String) -> Bool {
    guard value.count == 15 else { return false }
    var sum = 0
    for (index, character) in value.enumerated() {
      guard var digit = Int(String(character)) else { return false }
      if index % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
      sum += digit
    }
    return sum % 10 == 0
  }

  private func unique(_ evidence: [VisionEvidence]) -> [VisionEvidence] {
    Dictionary(grouping: evidence, by: { "\($0.source)-\($0.value)-\(Int($0.x * 20))-\(Int($0.topY * 20))" }).compactMap { $0.value.max { $0.confidence < $1.confidence } }
  }

  private func best(_ candidates: [VisionEvidence], value: String) -> Float { candidates.filter { $0.value == value }.map(\.confidence).max() ?? 0 }
  private func evidenceBoxes(_ evidence: [VisionEvidence]) -> [[String: Any]] { evidence.map { boxMap($0.box) } }
  private func boxMap(_ box: CGRect) -> [String: Any] { ["x": Double(box.origin.x), "y": Double(box.origin.y), "width": Double(box.width), "height": Double(box.height)] }
  private func sameLabel(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let horizontalOverlap = min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX)
    let minimumWidth = max(0.001, min(lhs.width, rhs.width))
    guard horizontalOverlap / minimumWidth > 0.25 else { return false }
    let verticalGap = max(0, max(lhs.minY, rhs.minY) - min(lhs.maxY, rhs.maxY))
    return verticalGap <= max(lhs.height, rhs.height) * 0.9
  }

  private func mappedPoint(_ boundingBox: CGRect, rotated: Bool, crop: CGRect, canvasSize: CGSize) -> (x: CGFloat, y: CGFloat) {
    let mapped = mappedRect(boundingBox, rotated: rotated, crop: crop, canvasSize: canvasSize)
    return (mapped.midX, mapped.midY)
  }

  private func mappedRect(_ boundingBox: CGRect, rotated: Bool, crop: CGRect, canvasSize: CGSize) -> CGRect {
    let x = (crop.minX + boundingBox.minX * crop.width) / canvasSize.width
    // CGImage crops use a top-left pixel origin while Vision boxes use a
    // bottom-left normalized origin. Convert the tile's bottom edge before
    // mapping the observation back to the complete image.
    let cropBottom = canvasSize.height - crop.maxY
    let yFromBottom = (cropBottom + boundingBox.minY * crop.height) / canvasSize.height
    let width = boundingBox.width * crop.width / canvasSize.width
    let height = boundingBox.height * crop.height / canvasSize.height
    let topOrigin = 1 - yFromBottom - height
    if rotated {
      return CGRect(x: 1 - x - width, y: 1 - topOrigin - height, width: width, height: height)
    }
    return CGRect(x: x, y: topOrigin, width: width, height: height)
  }

  private func uniqueBoxes(_ boxes: [CGRect]) -> [CGRect] {
    var result: [CGRect] = []
    for box in boxes where !result.contains(where: { $0.insetBy(dx: -0.015, dy: -0.015).intersects(box) }) {
      result.append(box)
    }
    return result
  }

  private func enhancedImage(_ image: CGImage) -> CGImage? {
    let source = CIImage(cgImage: image)
    let enhanced = source.applyingFilter("CIColorControls", parameters: [
      kCIInputSaturationKey: 0.0,
      kCIInputContrastKey: 1.35,
      kCIInputBrightnessKey: 0.0,
    ])
    return CIContext().createCGImage(enhanced, from: enhanced.extent)
  }

  private func normalizedImage(_ image: UIImage) -> CGImage? {
    guard let ciImage = CIImage(image: image) else { return image.cgImage }
    let oriented = ciImage.oriented(forExifOrientation: image.imageOrientation.exifOrientation)
    return CIContext().createCGImage(oriented, from: oriented.extent)
  }

  private func rotate180(_ image: CGImage) -> CGImage? {
    let size = CGSize(width: image.width, height: image.height)
    let renderer = UIGraphicsImageRenderer(size: size)
    let rotated = renderer.image { context in
      context.cgContext.translateBy(x: size.width, y: size.height)
      context.cgContext.rotate(by: .pi)
      context.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
    }
    return rotated.cgImage
  }
}

private extension UIImage.Orientation {
  var exifOrientation: Int32 {
    switch self {
    case .up: return 1
    case .down: return 3
    case .left: return 8
    case .right: return 6
    case .upMirrored: return 2
    case .downMirrored: return 4
    case .leftMirrored: return 5
    case .rightMirrored: return 7
    @unknown default: return 1
    }
  }
}
