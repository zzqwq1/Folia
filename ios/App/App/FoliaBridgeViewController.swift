import Foundation
import Capacitor

// ios/App/App/FoliaBridgeViewController.swift
//
// Capacitor 默认用 CAPBridgeViewController 直接做根控制器，App 内自带的插件不会被自动注册，
// 所以这里包一层，在 bridge 加载完成后手动登记 FoliaVisualizerPlugin。

class FoliaBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(FoliaVisualizerPlugin())
    }
}
