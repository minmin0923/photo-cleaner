//
//  ContentView.swift
//  스캔 → 그룹 검토(1장/2장 선택) → 최종 확인 화면 → 실행 흐름의 UI
//

import SwiftUI
import Photos

struct ContentView: View {
    @EnvironmentObject var vm: ScanViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle:
                    startScreen
                case .requestingPermission:
                    ProgressView("사진 접근 권한 확인 중…")
                case .denied:
                    deniedScreen
                case .scanning(let done, let total):
                    scanningScreen(done: done, total: total)
                case .review:
                    ReviewListView()
                case .processing:
                    ProgressView("처리 중…")
                case .finished(let count, let safeMode):
                    finishedScreen(count: count, safeMode: safeMode)
                }
            }
            .navigationTitle("사진 정리")
        }
    }

    // MARK: 시작 화면 + 설정
    private var startScreen: some View {
        Form {
            Section {
                Toggle(isOn: $vm.settings.safeMode) {
                    Label("안전 모드", systemImage: "shield.checkered")
                }
            } footer: {
                Text(vm.settings.safeMode
                     ? "켜짐: 사진을 삭제하지 않고 '\(kCandidateAlbumName)' 앨범에 모으기만 합니다. 실제 삭제는 사진 앱에서 직접 하세요. (권장)"
                     : "꺼짐: 앱에서 바로 삭제합니다. iOS 확인창을 거치며 '최근 삭제됨'에서 30일간 복구할 수 있습니다.")
            }
            Section("분석 범위") {
                Picker("대상 기간", selection: $vm.settings.recentDays) {
                    Text("최근 30일").tag(30)
                    Text("최근 90일").tag(90)
                    Text("최근 1년").tag(365)
                    Text("전체").tag(0)
                }
            }
            Section("중복 판정 기준") {
                VStack(alignment: .leading) {
                    Text("유사도 민감도: \(String(format: "%.2f", vm.settings.similarityThreshold))")
                        .font(.subheadline)
                    Slider(value: Binding(
                        get: { Double(vm.settings.similarityThreshold) },
                        set: { vm.settings.similarityThreshold = Float($0) }
                    ), in: 0.2...0.8, step: 0.05)
                    Text("낮을수록 엄격 (거의 똑같은 사진만 묶음). 처음에는 기본값 유지를 권장합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("촬영 간격 \(Int(vm.settings.timeWindow))초 이내",
                        value: $vm.settings.timeWindow, in: 30...600, step: 30)
            }
            Section {
                Toggle("iCloud 원본 다운로드 허용", isOn: $vm.settings.allowNetworkAccess)
            } footer: {
                Text("'저장공간 최적화'를 쓰는 경우 켜야 정확히 분석됩니다. 모든 분석은 기기 안에서만 이루어지며 사진이 외부로 전송되지 않습니다.")
            }
            Section {
                Button {
                    vm.startScan()
                } label: {
                    Label("스캔 시작", systemImage: "sparkle.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var deniedScreen: some View {
        ContentUnavailableView {
            Label("사진 접근 권한 필요", systemImage: "lock.fill")
        } description: {
            Text("설정 > 개인정보 보호 > 사진에서 접근을 허용해 주세요.")
        } actions: {
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func scanningScreen(done: Int, total: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .padding(.horizontal, 40)
            Text("분석 중 \(done) / \(total)")
                .font(.headline)
            Text("촬영 시간이 가까운 사진끼리 시각 유사도를 비교하고\n선명도·노출·얼굴 품질·눈 감음 여부를 채점합니다.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func finishedScreen(count: Int, safeMode: Bool) -> some View {
        ContentUnavailableView {
            Label(count > 0 ? "\(count)장 처리 완료" : "정리할 중복 사진 없음",
                  systemImage: count > 0 ? "checkmark.circle.fill" : "photo.on.rectangle")
        } description: {
            if count > 0 {
                Text(safeMode
                     ? "사진 앱의 '\(kCandidateAlbumName)' 앨범에 모였습니다.\n원본은 삭제되지 않았습니다. 앨범에서 확인 후 직접 삭제하세요."
                     : "삭제된 사진은 '최근 삭제됨' 앨범에서 30일간 복구할 수 있습니다.")
            } else {
                Text("설정에서 유사도 민감도를 높이거나 기간을 넓혀 다시 스캔해 보세요.")
            }
        } actions: {
            Button("처음으로") { vm.reset() }
        }
    }
}

// MARK: - 그룹 목록

struct ReviewListView: View {
    @EnvironmentObject var vm: ScanViewModel

    private var resolvedCount: Int { vm.groups.filter(\.resolved).count }
    private var pendingCount: Int {
        vm.groups.filter(\.resolved).map(\.deleteTargets.count).reduce(0, +)
    }

    var body: some View {
        List {
            if vm.skippedLoadFailures > 0 {
                Section {
                    Label("\(vm.skippedLoadFailures)장은 원본을 불러오지 못해 분석에서 제외했습니다. (해당 사진은 어떤 경우에도 건드리지 않습니다)",
                          systemImage: "exclamationmark.icloud")
                        .font(.caption)
                }
            }
            if vm.groups.isEmpty {
                ContentUnavailableView("중복 그룹 없음", systemImage: "photo.stack")
            }
            ForEach($vm.groups) { $group in
                NavigationLink {
                    GroupReviewView(group: $group)
                } label: {
                    GroupRowView(group: group)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if resolvedCount > 0 {
                VStack(spacing: 4) {
                    NavigationLink {
                        FinalConfirmView()
                    } label: {
                        Text("최종 확인으로 (\(resolvedCount)개 그룹 · \(pendingCount)장)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text(vm.settings.safeMode
                         ? "안전 모드: 삭제되지 않고 앨범에 모입니다."
                         : "직접 삭제 모드: 다음 화면에서 다시 한번 확인합니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .alert("오류", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .navigationTitle("중복 그룹 \(vm.groups.count)개")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GroupRowView: View {
    let group: PhotoGroup

    var body: some View {
        HStack(spacing: 12) {
            AssetThumbnail(asset: group.photos.first!.asset, side: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.photos.count)장 중복")
                    .font(.headline)
                Text(group.photos.first!.scoreReason)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if group.resolved {
                Label("\(group.keepIDs.count)장 남김", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }
}
