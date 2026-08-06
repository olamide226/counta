import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct CountaLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      // Lock Screen banner view
      HStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(Color(red: 0.1, green: 0.12, blue: 0.18))
            .frame(width: 44, height: 44)
          Image(systemName: "number.circle.fill")
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(.indigo)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(context.state.phrase ?? "Session")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
          
          HStack(spacing: 8) {
            Label("\(context.state.voiceCount ?? 0)", systemName: "mic.fill")
              .font(.caption2)
              .foregroundColor(.cyan)
            Label("\(context.state.manualCount ?? 0)", systemName: "hand.tap.fill")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 2) {
          Text("\(context.state.count ?? 0)")
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .foregroundColor(.white)
          Text((context.state.status ?? "live").capitalized)
            .font(.caption2)
            .bold()
            .foregroundColor(.green)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    } dynamicIsland: { context in
      DynamicIsland {
        // Expanded Dynamic Island region
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            Image(systemName: "number.circle.fill")
              .font(.title2)
              .foregroundColor(.indigo)
            VStack(alignment: .leading) {
              Text("Counta")
                .font(.caption2)
                .foregroundColor(.secondary)
              Text(context.state.phrase ?? "Session")
                .font(.subheadline)
                .bold()
                .lineLimit(1)
            }
          }
          .padding(.leading, 8)
        }

        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing) {
            Text("\(context.state.count ?? 0)")
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .foregroundColor(.white)
            Text((context.state.status ?? "live").capitalized)
              .font(.caption2)
              .foregroundColor(.green)
          }
          .padding(.trailing, 8)
        }

        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Label("Voice: \(context.state.voiceCount ?? 0)", systemName: "mic.fill")
              .font(.caption)
              .foregroundColor(.cyan)
            Spacer()
            Label("Tap: \(context.state.manualCount ?? 0)", systemName: "hand.tap.fill")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(.horizontal, 16)
          .padding(.top, 4)
        }
      } compactLeading: {
        Image(systemName: "number.circle.fill")
          .foregroundColor(.indigo)
      } compactTrailing: {
        Text("\(context.state.count ?? 0)")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .foregroundColor(.indigo)
      } minimal: {
        Text("\(context.state.count ?? 0)")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundColor(.indigo)
      }
    }
  }
}
