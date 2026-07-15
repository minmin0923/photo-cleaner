//
//  QualityScorer.swift
//  사진 1장의 품질 점수 산출: 선명도 + 노출 + 얼굴 촬영 품질 + 눈 뜸 여부
//

import UIKit
import Vision

struct QualityResult {
    var sharpness: Double      // 0~1
    var exposure: Double       // 0~1 (0.5 근처 밝기 + 클리핑 적을수록 높음)
    var faceQuality: Double?   // 0~1, 얼굴 없으면 nil
    var eyesOpen: Bool?        // 얼굴 있으나 판정 불가면 nil
    var faceCount: Int

    /// 종합 점수 — 얼굴이 있으면 인물 품질 중심, 없으면 배경(선명도/노출) 중심
    var totalScore: Double {
        if let fq = faceQuality, faceCount > 0 {
            let eyeScore: Double = {
                switch eyesOpen {
                case .some(true):  return 1.0
                case .some(false): return 0.0
                case .none:        return 0.6   // 판정 불가 → 중립보다 약간 위 (오탐 방지)
                }
            }()
            // 인물 사진: 얼굴 품질 55% + 눈 20% + 선명도 20% + 노출 5%
            return fq * 0.55 + eyeScore * 0.20 + sharpness * 0.20 + exposure * 0.05
        } else {
            // 풍경/사물: 선명도 70% + 노출 30%
            return sharpness * 0.70 + exposure * 0.30
        }
    }
}

enum QualityScorer {

    /// 메인 진입점 — 다운샘플된 CGImage를 받아 품질 분석
    static func score(cgImage: CGImage) -> QualityResult {
        let gray = grayscalePixels(from: cgImage, maxSide: 256)
        let sharp = gray.map { normalizedSharpness(pixels: $0.pixels, width: $0.width, height: $0.height) } ?? 0.5
        let expo  = gray.map { exposureScore(pixels: $0.pixels) } ?? 0.5

        var faceQuality: Double? = nil
        var eyesOpen: Bool? = nil
        var faceCount = 0

        // 1) 얼굴 촬영 품질 (Apple이 학습한 "잘 나온 얼굴" 점수)
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        // 2) 눈 감음 판정을 위한 랜드마크
        let landmarksRequest = VNDetectFaceLandmarksRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([qualityRequest, landmarksRequest])

            if let faces = qualityRequest.results, !faces.isEmpty {
                faceCount = faces.count
                let qualities = faces.compactMap { $0.faceCaptureQuality }.map(Double.init)
                if !qualities.isEmpty {
                    faceQuality = qualities.reduce(0, +) / Double(qualities.count)
                }
            }

            if let faces = landmarksRequest.results, !faces.isEmpty {
                if faceCount == 0 { faceCount = faces.count }
                var openVotes = 0, closedVotes = 0
                for face in faces {
                    guard let landmarks = face.landmarks else { continue }
                    // 얼굴이 너무 작으면 눈 판정 신뢰 불가 → 건너뜀 (한계 #5 대응)
                    if face.boundingBox.width < 0.08 { continue }
                    let ears = [landmarks.leftEye, landmarks.rightEye]
                        .compactMap { $0 }
                        .compactMap { eyeAspectRatio(points: $0.normalizedPoints) }
                    guard !ears.isEmpty else { continue }
                    let avgEAR = ears.reduce(0, +) / Double(ears.count)
                    if avgEAR < 0.14 { closedVotes += 1 } else { openVotes += 1 }
                }
                if openVotes + closedVotes > 0 {
                    // 한 명이라도 눈을 감았으면 '눈 감음' 처리 (단체사진 기준)
                    eyesOpen = (closedVotes == 0)
                }
            }
        } catch {
            // Vision 실패 시 얼굴 관련 점수는 nil 유지 → 배경 기준으로만 채점
        }

        return QualityResult(sharpness: sharp, exposure: expo,
                             faceQuality: faceQuality, eyesOpen: eyesOpen,
                             faceCount: faceCount)
    }

    // MARK: - 눈 종횡비 (EAR: Eye Aspect Ratio)
    /// 눈 윤곽점의 세로/가로 비율. 감은 눈은 세로가 좁아져 값이 작아짐.
    private static func eyeAspectRatio(points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let width = maxX - minX
        guard width > 0 else { return nil }
        return Double((maxY - minY) / width)
    }

    // MARK: - 그레이스케일 변환
    private static func grayscalePixels(from cgImage: CGImage, maxSide: Int)
        -> (pixels: [UInt8], width: Int, height: Int)? {
        let scale = min(1.0, CGFloat(maxSide) / CGFloat(max(cgImage.width, cgImage.height)))
        let w = max(1, Int(CGFloat(cgImage.width) * scale))
        let h = max(1, Int(CGFloat(cgImage.height) * scale))

        var pixels = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    // MARK: - 선명도: 라플라시안 분산
    private static func normalizedSharpness(pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2 else { return 0.5 }
        var sum = 0.0, sumSq = 0.0
        let count = Double((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let c = Double(pixels[row + x])
                let lap = Double(pixels[row + x - 1]) + Double(pixels[row + x + 1])
                        + Double(pixels[row - width + x]) + Double(pixels[row + width + x])
                        - 4 * c
                sum += lap
                sumSq += lap * lap
            }
        }
        let mean = sum / count
        let variance = sumSq / count - mean * mean
        // 경험적 정규화: 분산 0 → 0점, 500 이상 → 1점 (로그 스케일)
        let normalized = min(1.0, log10(1 + max(0, variance)) / log10(501))
        return normalized
    }

    // MARK: - 노출: 평균 밝기 적정성 + 클리핑 패널티
    private static func exposureScore(pixels: [UInt8]) -> Double {
        guard !pixels.isEmpty else { return 0.5 }
        let n = Double(pixels.count)
        var total = 0.0, blacks = 0, whites = 0
        for p in pixels {
            total += Double(p)
            if p < 8 { blacks += 1 }
            if p > 247 { whites += 1 }
        }
        let meanLuma = total / n / 255.0                       // 0~1
        let brightnessScore = 1.0 - min(1.0, abs(meanLuma - 0.5) * 2)  // 0.5에 가까울수록 높음
        let clipPenalty = min(1.0, (Double(blacks) + Double(whites)) / n * 4)
        return max(0, brightnessScore * (1 - clipPenalty * 0.6))
    }
}
