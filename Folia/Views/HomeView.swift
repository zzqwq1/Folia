//
//  HomeView.swift
//  Folia
//
//  首页：顶部标题 + 歌单网格墙。用 LazyVGrid 而非一次性铺满，
//  只渲染可视区域内的卡片，内存与帧率都由系统管理。
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var library: LibraryStore

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist) {
                            PlaylistCard(playlist: playlist)
                        }
                        .buttonStyle(PressableCardStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background)
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .task {
            await library.refresh()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Folia")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("动态歌词播放器")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            NavigationLink {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            }
            .padding(.top, 6)
        }
        .padding(.top, 8)
    }
}

// MARK: - 歌单卡片

struct PlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                artwork
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("歌曲 \(playlist.trackCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(10)
            }
            .frame(height: 150)
        }
        .foliaCard()
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = playlist.coverURL {
            AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.surfaceHigh, Theme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
