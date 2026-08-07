import ActivityKit
import WidgetKit
import SwiftUI

// Must match live_activities plugin structure exactly so ActivityKit recognizes the target
struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState
  public struct ContentState: Codable, Hashable { }
  // Must be a UUID, not a String: the plugin requests the activity with
  // `LiveActivitiesAppAttributes(id: UUID)`, and ActivityKit only matches a
  // widget whose attributes type is identical. It is also the prefix the plugin
  // uses for the shared UserDefaults keys read below.
  var id = UUID()
}

extension LiveActivitiesAppAttributes {
  func prefixedKey(_ key: String) -> String {
    return "\(id)_\(key)"
  }
}

// Access shared App Group storage
let sharedDefault = UserDefaults(suiteName: "group.com.ruach-tech.counta")

/// The Counta mark — the app icon's ring of prayer beads with one accent bead.
///
/// Drawn rather than bundled as an image: the Dynamic Island's compact slot is
/// under 20pt, and the app icon downscaled to that size smears its beads into a
/// solid donut. Vector circles stay crisp at every size the widget is asked for,
/// and sit on transparency so the mark works over the island's black.
struct CountaBeadRing: View {
  /// Diameter of the whole ring.
  let size: CGFloat
  /// Fewer, larger beads read better at island sizes; 12 matches the app icon.
  var beadCount: Int = 12
  /// Position of the accent bead, clockwise from the top.
  var highlightIndex: Int = 1

  private let beadColor = Color(red: 0.97, green: 0.95, blue: 0.89)
  private let accentColor = Color(red: 0.98, green: 0.79, blue: 0.45)

  /// Beads that just touch would be `πs / (n + π)` across; shrink slightly so
  /// they stay legible as separate dots instead of merging into a ring.
  private var beadDiameter: CGFloat {
    (.pi * size) / (CGFloat(beadCount) + .pi) * 0.88
  }

  var body: some View {
    ZStack {
      ForEach(0 ..< beadCount, id: \.self) { index in
        Circle()
          .fill(index == highlightIndex ? accentColor : beadColor)
          .frame(width: beadDiameter, height: beadDiameter)
          // offset leaves the layout frame centred, so rotationEffect swings
          // each bead around the ring's centre rather than its own.
          .offset(y: -(size - beadDiameter) / 2)
          .rotationEffect(.degrees(Double(index) / Double(beadCount) * 360))
      }
    }
    .frame(width: size, height: size)
  }
}

struct CountaLiveActivityLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      let phrase = sharedDefault?.string(forKey: context.attributes.prefixedKey("phrase")) ?? "Session"
      let count = sharedDefault?.integer(forKey: context.attributes.prefixedKey("count")) ?? 0
      let voiceCount = sharedDefault?.integer(forKey: context.attributes.prefixedKey("voiceCount")) ?? 0
      let manualCount = sharedDefault?.integer(forKey: context.attributes.prefixedKey("manualCount")) ?? 0
      let status = sharedDefault?.string(forKey: context.attributes.prefixedKey("status")) ?? "live"

      // Lock Screen banner
      HStack(spacing: 16) {
        ZStack {
          Circle()
            .fill(Color(red: 0.1, green: 0.12, blue: 0.18))
            .frame(width: 44, height: 44)
          CountaBeadRing(size: 30)
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(phrase)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
          
          HStack(spacing: 8) {
            Label("\(voiceCount)", systemImage: "mic.fill")
              .font(.caption2)
              .foregroundColor(.cyan)
            Label("\(manualCount)", systemImage: "hand.tap.fill")
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 2) {
          Text("\(count)")
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .foregroundColor(.white)
          Text(status.capitalized)
            .font(.caption2)
            .bold()
            .foregroundColor(.green)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(Color(red: 0.07, green: 0.08, blue: 0.12))
    } dynamicIsland: { context in
      let phrase = sharedDefault?.string(forKey: context.attributes.prefixedKey("phrase")) ?? "Session"
      let count = sharedDefault?.integer(forKey: context.attributes.prefixedKey("count")) ?? 0
      let voiceCount = sharedDefault?.integer(forKey: context.attributes.prefixedKey("voiceCount")) ?? 0
      let manualCount = sharedDefault?.integer(forKey: context.attributes.prefixedKey("manualCount")) ?? 0
      let status = sharedDefault?.string(forKey: context.attributes.prefixedKey("status")) ?? "live"

      return DynamicIsland {
        // Expanded Dynamic Island
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            CountaBeadRing(size: 22)
            VStack(alignment: .leading) {
              Text("Counta")
                .font(.caption2)
                .foregroundColor(.secondary)
              Text(phrase)
                .font(.subheadline)
                .bold()
                .lineLimit(1)
            }
          }
          .padding(.leading, 8)
        }

        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing) {
            Text("\(count)")
              .font(.system(size: 28, weight: .bold, design: .rounded))
              .foregroundColor(.white)
            Text(status.capitalized)
              .font(.caption2)
              .foregroundColor(.green)
          }
          .padding(.trailing, 8)
        }

        DynamicIslandExpandedRegion(.bottom) {
          HStack {
            Label("Voice: \(voiceCount)", systemImage: "mic.fill")
              .font(.caption)
              .foregroundColor(.cyan)
            Spacer()
            Label("Tap: \(manualCount)", systemImage: "hand.tap.fill")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(.horizontal, 16)
          .padding(.top, 4)
        }
      } compactLeading: {
        // 8 beads rather than 12: at this size a fuller ring closes into a solid
        // circle and stops reading as beads.
        CountaBeadRing(size: 18, beadCount: 8)
      } compactTrailing: {
        Text("\(count)")
          .font(.system(size: 14, weight: .bold, design: .rounded))
          .foregroundColor(.indigo)
      } minimal: {
        Text("\(count)")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .foregroundColor(.indigo)
      }
    }
  }
}
