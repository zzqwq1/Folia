//
//  CoverArt.swift
//  Folia
//
//  封面加载。AsyncImage 走系统 URLCache，配合 Lazy 容器只加载可视区域内的封面，
//  不会像 WebGL 一次性把所有图片解码进内存。
//

import SwiftUI

struct CoverArt: View {
    let url: URL?
    let size: CGFloat
    var radius: CGFloat = 10

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.22))) { phase in
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.surfaceHigh, Theme.surface],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.28, weight: .light))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
