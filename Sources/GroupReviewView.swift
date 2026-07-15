//
//  GroupReviewView.swift
//  그룹 상세: 점수순 사진 나열 → "1장/2장 남기기" 선택 → 수동 재지정 가능 → 확정
//

import SwiftUI
import Photos

struct GroupReviewView: View {
    @Binding var group: PhotoGroup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 몇 장 남길지 선택 (핵심 요구사항)
                VStack(alignment: .leading, spacing: 8) {
                    Text("몇 장을 남길까요?").font(.headline)
                    Picker("남길 장수", selection: $group.keepCount) {
                        Text("1장 남기기").tag(1)
                        Text("2장 남기기").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: group.keepCount) { _, _ in
                        group.manualKeepIDs = []   // 장수 바꾸면 자동 선택으로 리셋
                    }
                    Text("기본으로 점수가 높은 사진이 선택됩니다. 사진을 탭하면 직접 바꿀 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                // 사진 카드 (점수 내림차순)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(group.photos) { photo in
                        PhotoCard(photo: photo,
                                  isKept: group.keepIDs.contains(photo.id),
                                  isBest: photo.id == group.photos.first?.id)
                            .onTapGesture { toggleKeep(photo) }
                    }
                }
                .padding(.horizontal)

                // 요약 + 확정
                VStack(spacing: 8) {
                    let del = group.deleteTargets.count
                    Text("남김 \(group.keepIDs.count)장 · 삭제 예정 \(del)장")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button {
                        group.resolved = true
                        dismiss()
                    } label: {
                        Label("이 그룹 확정", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(group.keepIDs.isEmpty)

                    Button("이 그룹 건너뛰기 (삭제 안 함)") {
                        group.resolved = false
                        dismiss()
                    }
                    .font(.caption)
                }
                .padding()
            }
            .padding(.vertical)
        }
        .navigationTitle("\(group.photos.count)장 비교")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleKeep(_ photo: ScoredPhoto) {
        var keeps = group.keepIDs
        if keeps.contains(photo.id) {
            keeps.remove(photo.id)
        } else {
            // 남길 장수 초과 시 가장 점수 낮은 기존 선택을 해제
            if keeps.count >= group.keepCount,
               let lowest = group.photos.last(where: { keeps.contains($0.id) }) {
                keeps.remove(lowest.id)
            }
            keeps.insert(photo.id)
        }
        group.manualKeepIDs = keeps
    }
}

// MARK: - 사진 카드

struct PhotoCard: View {
    let photo: ScoredPhoto
    let isKept: Bool
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AssetThumbnail(asset: photo.asset, side: 170)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isKept ? Color.green : Color.red.opacity(0.6),
                                    lineWidth: isKept ? 3 : 1.5)
                    )
                Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isKept ? .green : .red)
                    .background(Circle().fill(.white))
                    .padding(6)
            }
            HStack(spacing: 4) {
                if isBest {
                    Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption)
                }
                Text("\(Int(photo.totalScore * 100))점")
                    .font(.caption.bold())
            }
            Text(photo.scoreReason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if photo.eyesOpen == false {
                Label("눈 감음 감지", systemImage: "eye.slash")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 썸네일 로더

struct AssetThumbnail: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(ProgressView())
            }
        }
        .frame(width: side)
        .clipped()
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            let scale = UIScreen.main.scale
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side * scale, height: side * scale),
                contentMode: .aspectFill,
                options: options
            ) { img, _ in
                if let img { self.image = img }
            }
        }
    }
}
