//
//  FoliaNativeApp.swift
//  Folia
//
//  原生 SwiftUI 入口。目标：系统级性能（AVPlayer + 原生渲染），
//  界面按 Web 版风格重绘。
//

import SwiftUI

@main
struct FoliaNativeApp: App {
    @StateObject private var player = PlayerEngine()
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    player.library = library
                }
        }
    }
}
