import SwiftUI

struct HealthView: View {
    @ObservedObject var monitor: SystemMonitor
    var online = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                statusBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live system snapshot")
                        .font(.title2.bold())
                    Text("Updated \(monitor.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(online ? "Online" : "Offline")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background((online ? Color.green : Color.gray).opacity(0.14))
                    .foregroundStyle(online ? .green : .secondary)
                    .clipShape(Capsule())
                Button("Refresh") {
                    monitor.refresh()
                }
            }

            gaugesGrid

            Divider()

            CapabilitiesCard(online: online)

            Divider()

            Text("Top processes")
                .font(.headline)

            processList
        }
        .cardStyle()
    }

    private var statusBadge: some View {
        Label(snapshot.statusColor == .green ? "Healthy" : (snapshot.statusColor == .yellow ? "Watch" : "Critical"),
              systemImage: "waveform.path.ecg")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(snapshot.statusColor.opacity(0.16))
            .foregroundStyle(snapshot.statusColor)
            .clipShape(Capsule())
    }

    private var snapshot: SystemSnapshot {
        monitor.snapshot
    }

    private var gaugesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            GaugeCard(title: "CPU Usage", value: snapshot.cpuUsage, unit: "%",
                      color: snapshot.cpuUsage < 50 ? .green : (snapshot.cpuUsage < 85 ? .yellow : .red))
            GaugeCard(title: "Memory", value: snapshot.memoryFraction * 100, unit: "%",
                      color: snapshot.memoryFraction < 0.75 ? .green : .red,
                      caption: "\(String(format: "%.1f", snapshot.memoryUsedGB)) of \(String(format: "%.1f", snapshot.memoryTotalGB)) GB")
            GaugeCard(title: "Disk", value: snapshot.diskFraction * 100, unit: "%",
                      color: snapshot.diskFraction < 0.9 ? .green : .red,
                      caption: "\(String(format: "%.1f", snapshot.diskUsedGB)) of \(String(format: "%.1f", snapshot.diskTotalGB)) GB")
            infoCard
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System info")
                .font(.subheadline.weight(.semibold))
            infoRow(label: "Uptime", value: uptimeString)
            infoRow(label: "Running processes", value: "\(snapshot.processCount)")
            if let battery = snapshot.batteryLevel {
                infoRow(label: "Battery", value: "\(Int(battery))%")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }

    private var uptimeString: String {
        let s = Int(snapshot.uptimeSeconds)
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let mins = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    private var processList: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.topProcesses.enumerated()), id: \.offset) { _, proc in
                HStack(spacing: 12) {
                    Text(proc.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(String(format: "%.1f", proc.memoryMB)) MB")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.vertical, 7)
                if proc.name != snapshot.topProcesses.last?.name {
                    Divider()
                }
            }
        }
    }
}

private struct GaugeCard: View {
    let title: String
    let value: Double
    let unit: String
    var color: Color
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Gauge(value: value, in: 0...100) {
                Text("\(Int(value.rounded()))\(unit)")
            } currentValueLabel: {
                EmptyView()
            }
            .gaugeStyle(.linearCapacity)
            .tint(color)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
