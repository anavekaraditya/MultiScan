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
  let evidence: [VisionEvidence]
  let barcodePayloads: [String]
  let rawText: String
  let barcodeBoxes: [CGRect]
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

    let first = read(image, rotated: false)
    let second = rotate180(image).map { read($0, rotated: true) } ?? VisionBatch(evidence: [], barcodePayloads: [], rawText: "", barcodeBoxes: [])
    let evidence = unique(first.evidence + second.evidence)
    let barcodePayloads = Array(Set(first.barcodePayloads + second.barcodePayloads))
    let allText = [first.rawText, second.rawText].filter { !$0.isEmpty }.joined(separator: "\n")
    let barcodeBoxes = first.barcodeBoxes + second.barcodeBoxes

    let groups = compactGroups(evidence)
    let positions = dynamicPositions(groups)
    var outputGroups = groups
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
      "processingVersion": "ios-vision-dynamic-layout-v3",
    ]
  }

  private func read(_ image: CGImage, rotated: Bool) -> VisionBatch {
    let barcodeRequest = VNDetectBarcodesRequest()
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
      barcodeBoxes.append(mappedRect(observation.boundingBox, rotated: rotated))
      let point = mappedPoint(observation.boundingBox, rotated: rotated)
      for value in validCandidates(payload) {
        evidence.append(VisionEvidence(value: value, source: "barcode", confidence: observation.confidence, x: point.x, topY: point.y, box: mappedRect(observation.boundingBox, rotated: rotated)))
      }
    }

    var lines: [String] = []
    for observation in textRequest.results ?? [] {
      guard let recognized = observation.topCandidates(1).first else { continue }
      lines.append(recognized.string)
      let point = mappedPoint(observation.boundingBox, rotated: rotated)
      for value in validCandidates(recognized.string) {
        evidence.append(VisionEvidence(value: value, source: "ocr", confidence: observation.confidence, x: point.x, topY: point.y, box: mappedRect(observation.boundingBox, rotated: rotated)))
      }
    }
    return VisionBatch(evidence: evidence, barcodePayloads: payloads, rawText: lines.joined(separator: "\n"), barcodeBoxes: barcodeBoxes)
  }

  private func compactGroups(_ evidence: [VisionEvidence]) -> [VisionGroup] {
    var groups: [VisionGroup] = []
    for item in evidence.sorted(by: { $0.topY == $1.topY ? $0.x < $1.x : $0.topY < $1.topY }) {
      if let index = groups.firstIndex(where: { abs($0.x - item.x) < 0.14 && abs($0.topY - item.topY) < 0.14 }) {
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
    var rows: [[VisionGroup]] = []
    for group in sorted {
      if let lastIndex = rows.indices.last {
        let rowY = rows[lastIndex].map(\.topY).reduce(0, +) / CGFloat(rows[lastIndex].count)
        if abs(rowY - group.topY) < 0.10 {
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
  private func mappedPoint(_ boundingBox: CGRect, rotated: Bool) -> (x: CGFloat, y: CGFloat) {
    let x = boundingBox.midX
    let topY = 1 - boundingBox.midY
    return rotated ? (1 - x, 1 - topY) : (x, topY)
  }

  private func mappedRect(_ boundingBox: CGRect, rotated: Bool) -> CGRect {
    if rotated {
      return CGRect(x: 1 - boundingBox.maxX, y: boundingBox.minY, width: boundingBox.width, height: boundingBox.height)
    }
    return CGRect(x: boundingBox.minX, y: 1 - boundingBox.maxY, width: boundingBox.width, height: boundingBox.height)
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
