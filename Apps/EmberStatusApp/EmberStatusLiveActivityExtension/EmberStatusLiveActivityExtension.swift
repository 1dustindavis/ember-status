import ActivityKit
import WidgetKit
import SwiftUI
import EmberCore

@main
struct EmberStatusLiveActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        EmberStatusLiveActivityWidget()
    }
}

struct EmberStatusLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EmberMugActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(.black.opacity(0.38))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.liquidState, systemImage: "mug.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if let temp = context.state.currentTempC {
                        Text("\(temp, specifier: "%.1f")°C")
                            .font(.headline)
                            .monospacedDigit()
                    } else {
                        Text("--")
                            .font(.headline)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        if let battery = context.state.batteryPercent {
                            Text("Battery \(battery)%")
                        } else {
                            Text("Battery --")
                        }

                        HStack(spacing: 4) {
                            Text("Updated")
                            Text(context.state.lastUpdatedAt, style: .timer)
                                .monospacedDigit()
                            Text("ago")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "mug.fill")
            } compactTrailing: {
                Text(shortState(context.state.liquidState))
                    .font(.caption2)
            } minimal: {
                Image(systemName: "mug.fill")
            }
            .widgetURL(URL(string: "emberstatus://status"))
            .keylineTint(.blue)
        }
    }

    private func shortState(_ text: String) -> String {
        if text.lowercased().contains("heat") { return "Hot" }
        if text.lowercased().contains("cool") { return "Cool" }
        return "--"
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<EmberMugActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.mugName)
                        .font(.headline)
                    Text(context.state.liquidState)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(temperatureText)
                    .font(.title3)
                    .monospacedDigit()
            }

            HStack(spacing: 14) {
                Label(batteryText, systemImage: "battery.25")
                Label {
                    HStack(spacing: 4) {
                        Text(context.state.lastUpdatedAt, style: .timer)
                            .monospacedDigit()
                        Text("ago")
                    }
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var temperatureText: String {
        guard let temp = context.state.currentTempC else { return "--" }
        return String(format: "%.1f°C", temp)
    }

    private var batteryText: String {
        guard let battery = context.state.batteryPercent else { return "Battery --" }
        if context.state.isCharging == true {
            return "Battery \(battery)% (Charging)"
        }
        return "Battery \(battery)%"
    }
}
