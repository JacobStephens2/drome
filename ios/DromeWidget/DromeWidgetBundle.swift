//
//  DromeWidgetBundle.swift
//  DromeWidget
//
//  Self-contained placeholder so the extension target builds and embeds.
//  The real widget (camel fill + interactive water presets via AppIntents)
//  lands in a later build stage and replaces the view/provider here.
//

import SwiftUI
import WidgetKit

@main
struct DromeWidgetBundle: WidgetBundle {
    var body: some Widget {
        DromePlaceholderWidget()
    }
}

struct DromePlaceholderEntry: TimelineEntry {
    let date: Date
}

struct DromePlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> DromePlaceholderEntry {
        DromePlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (DromePlaceholderEntry) -> Void) {
        completion(DromePlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DromePlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [DromePlaceholderEntry(date: .now)], policy: .never))
    }
}

struct DromePlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DromeWidget", provider: DromePlaceholderProvider()) { _ in
            VStack(spacing: 4) {
                Text("🐫")
                    .font(.largeTitle)
                Text("Drome")
                    .font(.headline)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Drome")
        .description("Your 75-day challenge at a glance.")
        .supportedFamilies([.systemSmall])
    }
}
