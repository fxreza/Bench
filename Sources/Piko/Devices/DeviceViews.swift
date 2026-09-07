import SwiftUI

/// Leading wing for a device connect/disconnect event: the device glyph,
/// 10 pt from the leading edge, vertically centered in the 92 pt wing x
/// notch-height frame (see docs/ARCHITECTURE.md's geometry contract), with a
/// subtle scale-in on appear.
struct DeviceLeadingView: View {
    let event: DeviceEvent
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: event.kind.symbolName)
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                appeared = true
            }
        }
    }
}

/// Trailing wing for a device event: name over either the connection state
/// or the battery reading, 12 pt from the trailing edge.
struct DeviceTrailingView: View {
    let event: DeviceEvent

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(event.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            secondaryLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if !event.isConnected {
            Text("Disconnected")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        } else if event.kind.reportsPerEarBattery, event.batteryLeft != nil || event.batteryRight != nil {
            perEarBatteryLine
        } else if let level = event.displayBattery {
            HStack(spacing: 3) {
                Image(systemName: DeviceBatterySymbol.closest(forLevel: level))
                    .font(.system(size: 9))
                Text("\(Int((level * 100).rounded()))%")
                    .font(.system(size: 10).monospacedDigit())
            }
            .foregroundStyle(.gray)
        } else {
            Text("Connected")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
    }

    private var perEarBatteryLine: some View {
        var parts: [String] = []
        if let left = event.batteryLeft { parts.append("L \(Int((left * 100).rounded()))%") }
        if let right = event.batteryRight { parts.append("R \(Int((right * 100).rounded()))%") }
        if let caseLevel = event.batteryCase { parts.append("Case \(Int((caseLevel * 100).rounded()))%") }
        return Text(parts.joined(separator: " "))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.gray)
    }
}

/// Leading wing for the low battery warning: the closest `battery.*` symbol
/// for the current level, in red, 10 pt from the leading edge.
struct LowBatteryLeadingView: View {
    let status: BatteryStatus
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: DeviceBatterySymbol.closest(forLevel: status.level))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                appeared = true
            }
        }
    }
}

/// Trailing wing for the low battery warning: "Low Battery" over the
/// remaining percentage.
struct LowBatteryTrailingView: View {
    let status: BatteryStatus

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("Low Battery")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(status.percent)% remaining")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

// MARK: - Helpers

private extension DeviceKind {
    /// AirPods-family devices report separate left/right (and case) levels
    /// instead of one figure.
    var reportsPerEarBattery: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax:
            return true
        default:
            return false
        }
    }
}

private enum DeviceBatterySymbol {
    /// Nearest discrete `battery.*` SF Symbol for a 0...1 level.
    static func closest(forLevel level: Double) -> String {
        let percent = Int((level * 100).rounded())
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
