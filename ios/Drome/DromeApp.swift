//
//  DromeApp.swift
//  Drome
//

import SwiftUI

@main
struct DromeApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
        }
    }
}
