//
//  DromeWidgetBundle.swift
//  DromeWidget
//
//  Widget extension entry point. The water quick-add widget lives in
//  WaterWidget.swift; its interactive intent in LogWaterIntent.swift.
//

import SwiftUI
import WidgetKit

@main
struct DromeWidgetBundle: WidgetBundle {
    var body: some Widget {
        WaterWidget()
    }
}
