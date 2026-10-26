//
//  RootView.swift
//  Folia
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var player: PlayerEngine
    @State private var showPlayer = false
    @Namespace private var playerTransition

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()

            NavigationStack {
                HomeView()
                    // 给底部播放条留出空间，避免遮住最后一个歌单。
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear.frame(height: player.current == nil ? 0 : 66)
                    }
            }

            miniPlayer
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView(transition: playerTransition)
                .environmentObject(player)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if player.current != nil {
            MiniPlayerBar(transition: playerTransition) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    showPlayer = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
