import SwiftUI

/// 搜索：原生版还没封装在线搜索接口，这里先用已加载的歌单做本地筛选，
/// 命中就直接进歌单详情。页面明确标出「本地筛选」，不假装是在线搜索。
struct FoliaSearchView: View {
    let playlists: [Playlist]
    let onOpenPlaylist: (Playlist) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Playlist] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return playlists }
        return playlists.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.creator?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            FoliaTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FoliaTheme.t3)
                    TextField("搜索歌单 / 创建者", text: $query)
                        .font(FoliaFont.sans(15))
                        .foregroundStyle(FoliaTheme.t1)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(FoliaTheme.t3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(FoliaTheme.card.opacity(0.9), in: Capsule())
                .overlay(Capsule().stroke(FoliaTheme.line, lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Text("本地筛选 · 已加载 \(playlists.count) 个歌单，在线搜索接口尚未接入")
                    .font(FoliaFont.mono(10))
                    .foregroundStyle(FoliaTheme.t3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                if results.isEmpty {
                    Text(playlists.isEmpty ? "还没有歌单，先在首页连接平台" : "没有匹配的歌单")
                        .font(FoliaFont.sans(13))
                        .foregroundStyle(FoliaTheme.t3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(results) { p in
                                Button {
                                    dismiss()
                                    onOpenPlaylist(p)
                                } label: {
                                    HStack(spacing: 12) {
                                        AsyncImage(url: URL(string: p.coverUrl ?? "")) { phase in
                                            switch phase {
                                            case .success(let img): img.resizable().scaledToFill()
                                            default: FoliaTheme.fill
                                            }
                                        }
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(p.title)
                                                .font(FoliaFont.sans(14, .medium))
                                                .foregroundStyle(FoliaTheme.t1)
                                                .lineLimit(1)
                                            Text(p.creator ?? p.provider.displayName)
                                                .font(FoliaFont.sans(11))
                                                .foregroundStyle(FoliaTheme.t3)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FoliaTheme.t1)
                    .frame(width: 40, height: 40)
                    .background(FoliaTheme.card.opacity(0.8), in: Circle())
                    .overlay(Circle().stroke(FoliaTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}
