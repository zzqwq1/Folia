//
//  SearchView.swift
//  Folia
//
//  搜索：输入关键词，结果点一行即从该行开始播。
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine

    @State private var keyword = ""
    @State private var results: [Track] = []
    @State private var hasSearched = false
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { track in
                        Button {
                            player.play(track, in: results)
                        } label: {
                            TrackRow(track: track,
                                     index: nil,
                                     isCurrent: player.current?.id == track.id)
                        }
                        .buttonStyle(.plain)

                        Divider()
                            .overlay(Theme.stroke)
                            .padding(.leading, 72)
                    }

                    if hasSearched && results.isEmpty && !busy {
                        Text("没有找到相关歌曲")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, 60)
                    }
                }
                .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textTertiary)

            TextField("搜索歌曲、歌手", text: $keyword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { runSearch() }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    results = []
                    hasSearched = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if busy {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private func runSearch() {
        focused = false
        let query = keyword
        busy = true
        Task {
            defer { busy = false }
            do {
                results = try await library.search(query)
            } catch {
                results = []
            }
            hasSearched = true
        }
    }
}
