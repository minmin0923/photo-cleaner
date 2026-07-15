//
//  FinalConfirmView.swift
//  실행 직전 최종 확인: 처리 대상 사진 전체를 그리드로 다시 보여주고,
//  사용자가 체크박스로 확인한 뒤에만 실행 버튼이 활성화됨.
//

import SwiftUI

struct FinalConfirmView: View {
    @EnvironmentObject var vm: ScanViewModel
    @State private var confirmed = false

    private var targets: [ScoredPhoto] {
        vm.groups.filter(\.resolved).flatMap(\.deleteTargets)
    }
    private var keepTotal: Int {
        vm.groups.filter(\.resolved).map { $0.keepIDs.count }.reduce(0, +)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 요약
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(vm.settings.safeMode
                              ? "아래 \(targets.count)장을 '\(kCandidateAlbumName)' 앨범에 모읍니다. 원본은 삭제되지 않습니다."
                              : "아래 \(targets.count)장을 삭제합니다. iOS 확인창이 한 번 더 표시되며 30일간 복구 가능합니다.",
                              systemImage: vm.settings.safeMode ? "shield.checkered" : "trash")
                            .font(.subheadline)
                        Text("남기는 사진 \(keepTotal)장은 그대로 유지됩니다. 확정하지 않은 그룹과 분석에서 제외된 사진은 어떤 경우에도 건드리지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // 처리 대상 전체 그리드
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(targets) { photo in
                        VStack(spacing: 2) {
                            AssetThumbnail(asset: photo.asset, side: 100)
                                .frame(height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.red.opacity(0.7), lineWidth: 1.5)
                                )
                            Text("\(Int(photo.totalScore * 100))점")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)

                // 확인 체크 + 실행
                VStack(spacing: 12) {
                    Toggle(isOn: $confirmed) {
                        Text("위 사진들을 모두 확인했습니다")
                            .font(.subheadline)
                    }
                    .toggleStyle(CheckboxToggleStyle())

                    Button {
                        vm.executeCleanup()
                    } label: {
                        Label(vm.settings.safeMode ? "앨범에 모으기" : "\(targets.count)장 삭제",
                              systemImage: vm.settings.safeMode ? "folder.badge.plus" : "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(vm.settings.safeMode ? .blue : .red)
                    .disabled(!confirmed || targets.isEmpty)
                }
                .padding()
            }
            .padding(.vertical)
        }
        .navigationTitle("최종 확인")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 체크박스 스타일 토글
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? .blue : .secondary)
                    .font(.title3)
                configuration.label
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
}
