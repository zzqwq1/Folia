import SwiftUI

/// 首页：海报墙。原版桌面是无限可拖拽的墙面（cellSize 128、gap 8），
/// 手机上改成同尺寸网格的自然滚动 —— 观感一致，但滚动、回弹、惯性全部交给系统。
struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @State private var openCollection: MusicCollection?
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 8, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.collections.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(library.collections) { collection in
                            Button {
                                openCollection = collection
                            } label: {
                                PosterCell(collection: collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 100)
                }
            }
            .scrollIndicators(.hidden)
            .background(FoliaTheme.background)
            .navigationTitle(library.account.map { "你好，\($0.nickname)" } ?? "Folia")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 20))
                    }
                }
            }
            .refreshable { await library.refresh() }
        }
        .tint(FoliaTheme.text)
        .sheet(item: $openCollection) { collection in
            CollectionView(collection: collection)
                .environmentObject(player)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(library)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if library.isLoading {
                ProgressView().tint(FoliaTheme.textSecondary)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 34))
                    .foregroundStyle(FoliaTheme.textSecondary)
                Text("还没有歌单")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(FoliaTheme.text)
                Text("在设置里扫码登录网易云，墙面就会铺满你的收藏")
                    .font(.system(size: 13))
                    .foregroundStyle(FoliaTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.horizontal, 32)
    }
}

private struct PosterCell: View {
    let collection: MusicCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: collection.cover(size: 320)) { phase in
                ZStack {
                    FoliaTheme.surface
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(FoliaTheme.textSecondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(collection.name)
                .font(.system(size: 12))
                .foregroundStyle(FoliaTheme.text)
                .lineLimit(1)
        }
    }
}
