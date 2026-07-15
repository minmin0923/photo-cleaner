//
//  PhotoCleanerApp.swift
//  PhotoCleaner — 아이폰 중복 사진 정리 앱
//
//  안전 설계 원칙:
//  1. 앱은 스스로 아무것도 삭제하지 않는다 — 사용자가 그룹별로 확정한 사진만 대상
//  2. 기본값은 '안전 모드' — 삭제 대신 "🗑 삭제후보" 앨범에 모으기만 함
//  3. 실행 전 최종 확인 화면에서 대상 전체를 다시 보여주고 체크 확인
//  4. 직접 삭제 시에도 iOS 시스템 확인창 + '최근 삭제됨' 30일 복구
//
//  모든 분석은 100% 온디바이스. 사진은 외부로 전송되지 않습니다.
//

import SwiftUI
import Photos

@main
struct PhotoCleanerApp: App {
    @StateObject private var scanner = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
        }
    }
}

// MARK: - 데이터 모델

/// 개별 사진 + 품질 점수
struct ScoredPhoto: Identifiable, Hashable {
    let id: String                 // PHAsset.localIdentifier
    let asset: PHAsset
    var totalScore: Double         // 0.0 ~ 1.0 종합 점수
    var sharpness: Double          // 선명도 (라플라시안 분산 정규화)
    var exposure: Double           // 노출 적정성
    var faceQuality: Double?       // Vision 얼굴 촬영 품질 (얼굴 없으면 nil)
    var eyesOpen: Bool?            // 눈 뜸 여부 (판정 불가면 nil)
    var faceCount: Int

    /// 점수 근거 요약 (UI 배지용)
    var scoreReason: String {
        var parts: [String] = []
        if let fq = faceQuality {
            parts.append("얼굴 \(Int(fq * 100))점")
        }
        if let eyes = eyesOpen {
            parts.append(eyes ? "눈 뜸" : "눈 감음")
        }
        parts.append("선명도 \(Int(sharpness * 100))")
        return parts.joined(separator: " · ")
    }

    static func == (lhs: ScoredPhoto, rhs: ScoredPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 중복 사진 그룹
struct PhotoGroup: Identifiable {
    let id = UUID()
    var photos: [ScoredPhoto]            // 점수 내림차순 정렬 상태 유지
    var keepCount: Int = 1               // 사용자가 선택: 1장 또는 2장 남기기
    var manualKeepIDs: Set<String> = []  // 사용자가 직접 지정한 '남길 사진' (비어있으면 점수순 자동)
    var resolved: Bool = false           // 이 그룹 정리 확정 여부 — 확정된 그룹만 처리 대상

    /// 실제로 남길 사진 ID 집합
    var keepIDs: Set<String> {
        if !manualKeepIDs.isEmpty {
            return manualKeepIDs
        }
        return Set(photos.prefix(keepCount).map(\.id))
    }

    /// 정리(삭제/앨범 이동) 대상
    var deleteTargets: [ScoredPhoto] {
        photos.filter { !keepIDs.contains($0.id) }
    }
}

/// 스캔 설정
struct ScanSettings {
    /// 같은 그룹으로 볼 최대 촬영 간격 (초)
    var timeWindow: TimeInterval = 90
    /// Vision FeaturePrint 거리 임계값 — 작을수록 엄격.
    /// 오탐 방지를 위해 보수적인 0.40을 기본값으로 사용 (거의 똑같은 사진만 묶임)
    var similarityThreshold: Float = 0.40
    /// iCloud 원본 다운로드 허용
    var allowNetworkAccess: Bool = true
    /// 분석 대상 최근 N일 (0 = 전체)
    var recentDays: Int = 30
    /// 안전 모드: true면 삭제하지 않고 "🗑 삭제후보" 앨범에 모으기만 함 (기본값 ON)
    var safeMode: Bool = true
}

/// 안전 모드에서 사용할 앨범 이름
let kCandidateAlbumName = "🗑 삭제후보 (PhotoCleaner)"
