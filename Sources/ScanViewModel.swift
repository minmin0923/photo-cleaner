//
//  ScanViewModel.swift
//  사진첩 스캔 → 시간창 + Vision FeaturePrint 유사도로 중복 그룹핑 → 품질 채점
//  → (안전 모드) 삭제후보 앨범에 모으기 / (직접 삭제 모드) iOS 확인창 거쳐 삭제
//
//  v2 수정 사항:
//  - [버그 수정] 의미 없는 잔여 코드 제거
//  - [버그 수정] 이미지 로드 실패 시 무한 대기 가능성 제거 (오류/취소 시 즉시 nil 반환)
//  - [기능 추가] 안전 모드: 삭제 대신 앨범에 모으기
//

import SwiftUI
import Photos
import Vision

@MainActor
final class ScanViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case requestingPermission
        case denied
        case scanning(done: Int, total: Int)
        case review                                      // 그룹 검토 단계
        case processing                                  // 앨범 이동 또는 삭제 실행 중
        case finished(count: Int, safeMode: Bool)
    }

    @Published var phase: Phase = .idle
    @Published var groups: [PhotoGroup] = []
    @Published var settings = ScanSettings()
    @Published var skippedLoadFailures: Int = 0          // iCloud 로드 실패 등
    @Published var errorMessage: String?

    private let imageManager = PHCachingImageManager()

    // MARK: - 권한 + 스캔 시작

    func startScan() {
        phase = .requestingPermission
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .authorized, .limited:
                    await self.scan()
                default:
                    self.phase = .denied
                }
            }
        }
    }

    // MARK: - 메인 스캔 파이프라인

    private func scan() async {
        // 1) 사진 가져오기 (버스트 대표컷만, 촬영시간 오름차순)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = false
        if settings.recentDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -settings.recentDays, to: Date())!
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@",
                                            PHAssetMediaType.image.rawValue, cutoff as NSDate)
        } else {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard assets.count >= 2 else {
            groups = []
            phase = .review
            return
        }

        skippedLoadFailures = 0

        // 2) 시간창(timeWindow) 기반 후보 묶음
        var rawGroups: [[PHAsset]] = []
        var current: [PHAsset] = []
        var lastDate: Date?

        for asset in assets {
            let date = asset.creationDate ?? .distantPast
            if let last = lastDate, date.timeIntervalSince(last) <= settings.timeWindow {
                current.append(asset)
            } else {
                if current.count >= 2 { rawGroups.append(current) }
                current = [asset]
            }
            lastDate = date
        }
        if current.count >= 2 { rawGroups.append(current) }

        // 3) 각 시간 묶음 내부에서 시각 유사도로 세분화 + 채점
        var finalGroups: [PhotoGroup] = []
        var processed = 0
        let totalCandidates = rawGroups.reduce(0) { $0 + $1.count }
        phase = .scanning(done: 0, total: max(totalCandidates, 1))

        for bucket in rawGroups {
            var analyzed: [(asset: PHAsset, print: VNFeaturePrintObservation?, quality: QualityResult?)] = []

            for asset in bucket {
                let image = await loadCGImage(asset: asset, targetSize: 512)
                if let cg = image {
                    let fp = try? featurePrint(cgImage: cg)
                    let q = QualityScorer.score(cgImage: cg)
                    analyzed.append((asset, fp, q))
                } else {
                    // 로드 실패한 사진은 그룹핑에서 완전히 제외 → 실수 삭제 원천 차단
                    skippedLoadFailures += 1
                }
                processed += 1
                phase = .scanning(done: processed, total: max(totalCandidates, 1))
                await Task.yield()   // UI 응답성 유지
            }

            // 유사도 기반 연결: 그룹 첫 사진(anchor)과 threshold 이내면 같은 그룹
            var subGroups: [[(asset: PHAsset, print: VNFeaturePrintObservation?, quality: QualityResult?)]] = []
            for item in analyzed {
                guard let fp = item.print else { continue }
                if var last = subGroups.last,
                   let anchor = last.first?.print,
                   distance(anchor, fp) <= settings.similarityThreshold {
                    last.append(item)
                    subGroups[subGroups.count - 1] = last
                } else {
                    subGroups.append([item])
                }
            }

            for sub in subGroups where sub.count >= 2 {
                var photos = sub.compactMap { item -> ScoredPhoto? in
                    guard let q = item.quality else { return nil }
                    return ScoredPhoto(id: item.asset.localIdentifier,
                                       asset: item.asset,
                                       totalScore: q.totalScore,
                                       sharpness: q.sharpness,
                                       exposure: q.exposure,
                                       faceQuality: q.faceQuality,
                                       eyesOpen: q.eyesOpen,
                                       faceCount: q.faceCount)
                }
                guard photos.count >= 2 else { continue }
                photos.sort { $0.totalScore > $1.totalScore }   // 최고점이 맨 앞
                finalGroups.append(PhotoGroup(photos: photos))
            }
        }

        groups = finalGroups
        phase = .review
    }

    // MARK: - Vision FeaturePrint

    private nonisolated func featurePrint(cgImage: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first as? VNFeaturePrintObservation else {
            throw NSError(domain: "PhotoCleaner", code: 1)
        }
        return obs
    }

    private nonisolated func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return d
    }

    // MARK: - 이미지 로드 (iCloud 대응, 무한 대기 방지)

    private func loadCGImage(asset: PHAsset, targetSize: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = settings.allowNetworkAccess
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isSynchronous = false

            var resumed = false
            func finish(_ image: CGImage?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }

            imageManager.requestImage(for: asset,
                                      targetSize: CGSize(width: targetSize, height: targetSize),
                                      contentMode: .aspectFit,
                                      options: options) { image, info in
                // 오류·취소 시 즉시 종료 (v1의 무한 대기 가능성 제거)
                if info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool) == true {
                    finish(nil)
                    return
                }
                // 저화질 중간 콜백은 건너뛰고 최종 콜백만 사용
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                finish(image?.cgImage)
            }
        }
    }

    // MARK: - 실행 (안전 모드 / 직접 삭제 모드)

    /// 확정(resolved)된 그룹의 정리 대상만 처리. 그 외 사진은 어떤 경우에도 건드리지 않음.
    func executeCleanup() {
        let targets = groups.filter(\.resolved).flatMap(\.deleteTargets).map(\.asset)
        guard !targets.isEmpty else {
            phase = .finished(count: 0, safeMode: settings.safeMode)
            return
        }
        phase = .processing

        if settings.safeMode {
            collectToAlbum(assets: targets)
        } else {
            deleteAssets(targets)
        }
    }

    /// 안전 모드: "🗑 삭제후보" 앨범에 추가만 (원본은 그대로 유지됨)
    private func collectToAlbum(assets: [PHAsset]) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title == %@", kCandidateAlbumName)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        let existingAlbum = existing.firstObject

        PHPhotoLibrary.shared().performChanges({
            let request: PHAssetCollectionChangeRequest?
            if let album = existingAlbum {
                request = PHAssetCollectionChangeRequest(for: album)
            } else {
                request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: kCandidateAlbumName)
            }
            request?.addAssets(assets as NSArray)
        }) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.phase = .finished(count: assets.count, safeMode: true)
                } else {
                    self.errorMessage = error?.localizedDescription ?? "앨범 추가에 실패했습니다."
                    self.phase = .review
                }
            }
        }
    }

    /// 직접 삭제 모드: iOS 시스템 확인창이 뜨고, 이후에도 '최근 삭제됨'에서 30일 복구 가능
    private func deleteAssets(_ assets: [PHAsset]) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.phase = .finished(count: assets.count, safeMode: false)
                } else {
                    self.errorMessage = error?.localizedDescription ?? "삭제가 취소되었거나 실패했습니다."
                    self.phase = .review
                }
            }
        }
    }

    func reset() {
        groups = []
        skippedLoadFailures = 0
        errorMessage = nil
        phase = .idle
    }
}
