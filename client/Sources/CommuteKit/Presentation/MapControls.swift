import SwiftUI

/// The commute / schedule switch (left) and, in schedule mode, which day's trains (right).
struct MapControls: View {
    let viewModel: CommuteViewModel
    let onModeChange: () -> Void
    let onNeedsAddresses: () -> Void

    var body: some View {
        HStack {
            Button {
                guard viewModel.hasAddresses else {
                    onNeedsAddresses()
                    return
                }
                onModeChange()
                Task { await viewModel.toggleMode() }
            } label: {
                ModeSwitch(mode: viewModel.mode)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isLoaded)
            .accessibilityLabel("Mode")
            .accessibilityValue(viewModel.mode.title)
            .accessibilityHint("Switches to \(viewModel.mode.other.title.lowercased())")
            .accessibilityIdentifier("mode-switch")

            Spacer()

            if let day = viewModel.scheduleDay {
                ScheduleKindPill(day: day, isSchedule: viewModel.mode == .schedule) {
                    Task { await viewModel.toggleScheduleKind() }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: viewModel.mode)
    }
}

/// Which timetable the trains on screen run on: "Weekday", "Weekend" or "Holiday". In schedule
/// mode a tap flips between weekday and weekend; in commute mode it's only a label.
private struct ScheduleKindPill: View {
    let day: ScheduleDay
    let isSchedule: Bool
    let onToggle: () -> Void

    var body: some View {
        if isSchedule {
            Button(action: onToggle) {
                label(showsToggle: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timetable")
            .accessibilityValue(title)
            .accessibilityHint("Switches between weekday and weekend trains")
            .accessibilityIdentifier("schedule-kind")
        } else {
            label(showsToggle: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title) timetable")
        }
    }

    private var title: String {
        day.holidayName == nil ? day.kind.rawValue.capitalized : "Holiday"
    }

    private func label(showsToggle: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .contentTransition(.opacity)
            if showsToggle {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(showsToggle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .animation(.smooth(duration: 0.25), value: title)
    }
}

/// Both modes side by side, the current one highlighted, so it reads as a switch.
private struct ModeSwitch: View {
    let mode: AppMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.commute, symbol: "briefcase.fill")
            segment(.schedule, symbol: "calendar")
        }
        .padding(3)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private func segment(_ segment: AppMode, symbol: String) -> some View {
        let isSelected = segment == mode
        return HStack(spacing: 5) {
            Image(systemName: symbol)
            if isSelected {
                Text(segment.title)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, isSelected ? 12 : 10)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                Capsule().fill(.tint)
            }
        }
        .contentShape(Capsule())
    }
}
