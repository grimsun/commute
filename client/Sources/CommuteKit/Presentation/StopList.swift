import SwiftUI

/// A train's stops from the rider's station to their destination, with where it is now.
struct StopList: View {
    let path: TrainPath
    let originID: String
    let destinationID: String
    let delay: TimeInterval
    let now: Date
    /// Starts folded to the ends and where the train is now; a tap shows every stop.
    var isCondensed = false

    @State private var showsAll = false

    private enum Item: Identifiable {
        case stop(index: Int)
        /// Stops folded away between two shown ones.
        case gap(after: Int, count: Int)

        var id: String {
            switch self {
            case .stop(let index): "stop-\(index)"
            case .gap(let after, _): "gap-\(after)"
            }
        }
    }

    var body: some View {
        let stops = path.stops(from: originID, to: destinationID)
        let position = path.position(at: now, delay: delay)
        // Highlighted only once the train is moving toward the rider's stops.
        let next = position == nil ? nil : path.nextStop(at: now, delay: delay)
        let current = stops.firstIndex { $0.stationID == (position?.stationID ?? next?.stationID) }
        let items = items(count: stops.count, current: current)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .stop(let index):
                    stopRow(stops[index], isFirst: index == 0, position: position, next: next)
                case .gap(_, let count):
                    gapRow(count: count)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCondensed, stops.count > 3 else { return }
            withAnimation(.smooth(duration: 0.3)) {
                showsAll.toggle()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCondensed ? .isButton : [])
        .accessibilityHint(isCondensed ? (showsAll ? "Shows fewer stops" : "Shows every stop") : "")
    }

    /// Every stop, or the first, the current one and the last with gaps between.
    private func items(count: Int, current: Int?) -> [Item] {
        guard isCondensed, !showsAll, count > 3 else { return (0..<count).map { .stop(index: $0) } }
        let shown = Set([0, count - 1] + (current.map { [$0] } ?? [])).sorted()
        var items: [Item] = []
        for (position, index) in shown.enumerated() {
            if position > 0 {
                let hidden = index - shown[position - 1] - 1
                if hidden > 0 {
                    items.append(.gap(after: shown[position - 1], count: hidden))
                }
            }
            items.append(.stop(index: index))
        }
        return items
    }

    private func stopRow(_ stop: TrainPath.StopTime, isFirst: Bool, position: TrainPosition?, next: TrainPath.StopTime?) -> some View {
        let passed = stop.departure.addingTimeInterval(delay) < now && position?.stationID != stop.stationID
        let isEnd = stop.stationID == originID || stop.stationID == destinationID
        let isNext = stop.stationID == next?.stationID
        return HStack(spacing: 10) {
            // The rail: a dot per stop joined by a line; the current stop is a ring.
            ZStack {
                if !isFirst {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).offset(y: -11).frame(height: 22)
                }
                Circle()
                    .fill(isNext ? Color.green : position?.stationID == stop.stationID ? Color.accentColor : (passed ? Color.secondary.opacity(0.4) : Color.secondary))
                    .frame(width: isEnd || isNext ? 9 : 7, height: isEnd || isNext ? 9 : 7)
            }
            .frame(width: 14, height: 22)

            Text(StationCatalog.station(id: stop.stationID)?.name ?? stop.stationID)
                .font(.subheadline.weight(isEnd || isNext ? .semibold : .regular))
                .foregroundStyle(isNext ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
            Spacer()
            Text(Format.time((stop.stationID == destinationID ? stop.arrival : stop.departure).addingTimeInterval(delay)))
                .font(.subheadline)
                .monospacedDigit()
        }
        .foregroundStyle(passed ? .secondary : .primary)
        .opacity(passed ? 0.6 : 1)
        .transition(.opacity)
    }

    /// A dashed stretch of rail: "5 stops".
    private func gapRow(count: Int) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 2, height: 22)
                .mask {
                    VStack(spacing: 3) {
                        ForEach(0..<5, id: \.self) { _ in Rectangle().frame(height: 2) }
                    }
                }
                .frame(width: 14)
            HStack(spacing: 4) {
                Text(count == 1 ? "1 stop" : "\(count) stops")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.tint)
        }
        .transition(.opacity)
    }
}
