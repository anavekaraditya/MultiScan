import Flutter
import CoreImage
import UIKit
import Vision
import VisionKit

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
    if call.method == "startLiveScan" {
      guard #available(iOS 16.0, *) else {
        result(FlutterError(code: "UNSUPPORTED", message: "Live scanning requires iOS 16 or later.", details: nil))
        return
      }
      let arguments = call.arguments as? [String: Any]
      let rows = max(1, (arguments?["rows"] as? Int) ?? 4)
      let columns = max(1, (arguments?["columns"] as? Int) ?? 16)
      Task { @MainActor in self.presentLiveScanner(rows: rows, columns: columns, result: result) }
      return
    }
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

  @MainActor
  @available(iOS 16.0, *)
  private func presentLiveScanner(rows: Int, columns: Int, result: @escaping FlutterResult) {
    guard DataScannerViewController.isSupported else {
      result(FlutterError(code: "UNSUPPORTED", message: "This iPhone does not support live text scanning.", details: nil))
      return
    }
    guard DataScannerViewController.isAvailable else {
      result(FlutterError(code: "UNAVAILABLE", message: "Live scanning is unavailable. Check camera permission and device restrictions.", details: nil))
      return
    }
    guard let presenter = topViewController() else {
      result(FlutterError(code: "PRESENTER_UNAVAILABLE", message: "Could not open the live scanner.", details: nil))
      return
    }
    let scanner = LiveVisionScannerViewController(rows: rows, columns: columns, completion: result)
    presenter.present(scanner, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
    var controller = window?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }
}

@available(iOS 16.0, *)
private final class LiveVisionScannerViewController: UIViewController, DataScannerViewControllerDelegate {
  private let completion: FlutterResult
  private let scanner: DataScannerViewController
  private var observations: [String: LiveObservation] = [:]
  private var finished = false
  private let expectedRows: Int
  private let expectedColumns: Int
  private let progressLabel = UILabel()
  private let detectedBadge = UILabel()
  private let detectionOverlay = LiveDetectionOverlay()

  init(rows: Int, columns: Int, completion: @escaping FlutterResult) {
    self.expectedRows = rows
    self.expectedColumns = columns
    self.completion = completion
    self.scanner = DataScannerViewController(
      recognizedDataTypes: [.text(), .barcode()],
      qualityLevel: .accurate,
      recognizesMultipleItems: true,
      isHighFrameRateTrackingEnabled: true,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    scanner.delegate = self
    addChild(scanner)
    scanner.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scanner.view)
    NSLayoutConstraint.activate([
      scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
      scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
    scanner.didMove(toParent: self)

    detectionOverlay.translatesAutoresizingMaskIntoConstraints = false
    detectionOverlay.backgroundColor = .clear
    detectionOverlay.isOpaque = false
    detectionOverlay.isUserInteractionEnabled = false
    view.addSubview(detectionOverlay)
    NSLayoutConstraint.activate([
      detectionOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      detectionOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      detectionOverlay.topAnchor.constraint(equalTo: view.topAnchor),
      detectionOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])

    let done = UIButton(type: .system)
    done.setTitle("Done", for: .normal)
    done.setTitleColor(.white, for: .normal)
    done.titleLabel?.font = .boldSystemFont(ofSize: 17)
    done.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    done.layer.cornerRadius = 12
    done.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
    done.addTarget(self, action: #selector(finish), for: .touchUpInside)
    done.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(done)
    NSLayoutConstraint.activate([
      done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
      done.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18)
    ])
    progressLabel.text = "0 / \(expectedRows * expectedColumns) detected"
    progressLabel.textColor = .white
    progressLabel.font = .boldSystemFont(ofSize: 16)
    progressLabel.textAlignment = .center
    progressLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    progressLabel.layer.cornerRadius = 12
    progressLabel.clipsToBounds = true
    progressLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(progressLabel)
    NSLayoutConstraint.activate([
      progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      progressLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
      progressLabel.heightAnchor.constraint(equalToConstant: 42),
      progressLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
    ])
    detectedBadge.text = "  Waiting for codes…  "
    detectedBadge.textColor = .white
    detectedBadge.font = .boldSystemFont(ofSize: 14)
    detectedBadge.textAlignment = .center
    detectedBadge.backgroundColor = UIColor.black.withAlphaComponent(0.68)
    detectedBadge.layer.cornerRadius = 14
    detectedBadge.clipsToBounds = true
    detectedBadge.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(detectedBadge)
    NSLayoutConstraint.activate([
      detectedBadge.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      detectedBadge.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
      detectedBadge.heightAnchor.constraint(equalToConstant: 34),
      detectedBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 190)
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    do {
      try scanner.startScanning()
      detectedBadge.text = "  Capturing for 5 seconds…  "
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        self?.finish()
      }
    }
    catch { fail(message: error.localizedDescription) }
  }

  func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { record(allItems) }
  func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) { record(allItems) }
  func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) { record(allItems) }
  func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { fail(message: "Live scanner became unavailable.") }

  private func record(_ items: [RecognizedItem]) {
    for item in items {
      let value: String?
      switch item {
      case .text(let text): value = normalizedCandidate(text.transcript)
      case .barcode(let barcode): value = normalizedCandidate(barcode.payloadStringValue)
      @unknown default: value = nil
      }
      guard let value else { continue }
      let box = normalizedBox(item.bounds)
      let confidence: Float = 0.95
      if var existing = observations[value] {
        existing.reads += 1
        existing.confidence = max(existing.confidence, confidence)
        existing.box = box
        observations[value] = existing
      } else {
        observations[value] = LiveObservation(value: value, reads: 1, confidence: confidence, box: box)
      }
    }
    let detected = min(observations.count, expectedRows * expectedColumns)
    let stableDetected = min(observations.values.filter { $0.reads >= 3 }.count, expectedRows * expectedColumns)
    progressLabel.text = "\(detected) / \(expectedRows * expectedColumns) detected"
    detectedBadge.text = stableDetected == 0 ? "  Checking codes…  " : "  ✓ Confirmed · \(stableDetected)  ·  Hold steady  "
    detectedBadge.backgroundColor = stableDetected == 0 ? UIColor.black.withAlphaComponent(0.68) : UIColor.systemGreen.withAlphaComponent(0.88)
    detectionOverlay.update(observations.values)
  }

  private func normalizedCandidate(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let digits = raw.replacingOccurrences(of: "[Oo]", with: "0", options: .regularExpression)
      .replacingOccurrences(of: "[Il]", with: "1", options: .regularExpression)
      .filter { $0.isNumber }
    guard digits.count == 15, isValidIMEI(digits) else { return nil }
    return digits
  }

  private func isValidIMEI(_ value: String) -> Bool {
    let digits = value.compactMap { Int(String($0)) }
    guard digits.count == 15 else { return false }
    let checksum = digits.enumerated().reduce(0) { total, pair in
      let (index, digit) = pair
      if index == 14 { return total }
      let transformed = index.isMultiple(of: 2) ? digit : (digit * 2 > 9 ? digit * 2 - 9 : digit * 2)
      return total + transformed
    }
    return (checksum + digits[14]) % 10 == 0
  }

  private func normalizedBox(_ bounds: RecognizedItem.Bounds) -> CGRect {
    let width = max(view.bounds.width, 1)
    let height = max(view.bounds.height, 1)
    let points = [bounds.topLeft, bounds.topRight, bounds.bottomLeft, bounds.bottomRight]
    let minX = points.map(\.x).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    return CGRect(x: minX / width, y: minY / height, width: max(0, maxX - minX) / width, height: max(0, maxY - minY) / height)
  }

  @objc private func finish() {
    guard !finished else { return }
    finished = true
    scanner.stopScanning()
    Task { @MainActor in
      do {
        let image = try await scanner.capturePhoto()
        let path = NSTemporaryDirectory() + "multiscan-live-\(UUID().uuidString).jpg"
        try image.jpegData(compressionQuality: 0.98)?.write(to: URL(fileURLWithPath: path))
        complete(imagePath: path)
      } catch {
        complete(imagePath: "")
      }
    }
  }

  private func complete(imagePath: String) {
    let stableObservations = observations.values.filter { $0.reads >= 3 }
    // Use spatial ordering rather than direct box-to-cell quantization. The
    // latter can put two nearby boxes into one cell because VisionKit boxes
    // include the printed text and barcode with slightly different bounds.
    let ordered = stableObservations.sorted { $0.box.midY == $1.box.midY ? $0.box.midX < $1.box.midX : $0.box.midY < $1.box.midY }
    var cells: [[String: Any]] = []
    for row in 0..<expectedRows {
      for column in 0..<expectedColumns {
        let position = "R\(row + 1)C\(column + 1)"
        let index = row * expectedColumns + column
        let selected = index < ordered.count ? ordered[index] : nil
        let status = selected == nil ? "retake" : "accepted"
        let reason = selected == nil ? "No confirmed 15-digit value detected" : "Stable, unique IMEI confirmed across live frames"
        var cell: [String: Any] = ["position": position, "status": status, "source": "visionkit-live", "confidence": Double(selected?.confidence ?? 0), "reason": reason, "boxes": selected.map { [["x": $0.box.minX, "y": $0.box.minY, "width": $0.box.width, "height": $0.box.height]] } ?? []]
        if let selected { cell["imei"] = selected.value }
        cells.append(cell)
      }
    }
    dismiss(animated: true) { self.completion(["cells": cells, "barcodeValues": [], "rawText": ordered.map(\.value).joined(separator: "\n"), "rawBarcodeCount": 0, "uniqueBarcodeCount": stableObservations.count, "groupCount": cells.count, "processingVersion": "ios-visionkit-live-v3", "imagePath": imagePath]) }
  }

  private func fail(message: String) { guard !finished else { return }; finished = true; dismiss(animated: true) { self.completion(FlutterError(code: "LIVE_SCAN_ERROR", message: message, details: nil)) } }
}

@available(iOS 16.0, *)
private final class LiveDetectionOverlay: UIView {
  private var observations: [LiveObservation] = []

  func update(_ observations: Dictionary<String, LiveObservation>.Values) {
    self.observations = Array(observations)
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    for observation in observations {
      let box = CGRect(
        x: observation.box.minX * bounds.width,
        y: observation.box.minY * bounds.height,
        width: observation.box.width * bounds.width,
        height: observation.box.height * bounds.height
      ).insetBy(dx: -5, dy: -5)
      let confirmed = observation.reads >= 3
      let color = confirmed ? UIColor.systemGreen : UIColor.systemYellow
      context.setStrokeColor(color.cgColor)
      context.setLineWidth(3)
      context.stroke(box)

      let label = confirmed ? "✓ \(observation.value)" : "… \(observation.value)"
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.boldSystemFont(ofSize: 12),
        .foregroundColor: UIColor.black,
        .backgroundColor: color
      ]
      let labelRect = CGRect(x: box.minX, y: max(0, box.minY - 20), width: min(bounds.width - box.minX, 150), height: 18)
      (label as NSString).draw(in: labelRect, withAttributes: attributes)
    }
  }
}

@available(iOS 16.0, *)
private struct LiveObservation { let value: String; var reads: Int; var confidence: Float; var box: CGRect }

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
