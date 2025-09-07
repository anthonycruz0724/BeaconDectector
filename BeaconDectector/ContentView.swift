//  ContentView.swift
//  BeaconDetector (iBeacon-only, 3 UUIDs)
//  Updated: 2025-09-06

import SwiftUI
import CoreLocation

// MARK: - Model

struct TrackedBeacon: Identifiable, Hashable {
    let id: String                 // uuid-major-minor
    let uuid: UUID
    let major: UInt16
    let minor: UInt16
    var rssi: Int
    var rawDistance: Double        // CLBeacon.accuracy (meters, -1 if unknown)
    var smoothedDistance: Double   // EMA-smoothed distance (meters)
    var proximity: CLProximity
    var lastSeen: Date
}

// MARK: - Ranger

final class BeaconRanger: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var beacons: [TrackedBeacon] = []
    
    private let manager = CLLocationManager()
    private var constraints: [CLBeaconIdentityConstraint] = []
    private var map: [String: TrackedBeacon] = [:]
    
    // Smoothing factor for distance EMA (0..1). Higher = more responsive, lower = smoother.
    private let alpha = 0.35
    
    /// Replace these with your three iBeacon UUIDs
    private let allowedUUIDStrings = [
        "1B6295D5-4F74-4C58-A2D8-CD83CA26BDF3",
        "1B6295D5-4F74-4C58-A2D8-CD83CA26BDF4",
        "1B6295D5-4F74-4C58-A2D8-CD83CA26BDF5"
    ]
    
    override init() {
        super.init()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        
        constraints = allowedUUIDStrings.compactMap { CLBeaconIdentityConstraint(uuid: UUID(uuidString: $0)!) }
    }
    
    func start() {
        guard CLLocationManager.authorizationStatus() == .authorizedWhenInUse
                || CLLocationManager.authorizationStatus() == .authorizedAlways else { return }
        for c in constraints {
            manager.startRangingBeacons(satisfying: c)
        }
    }
    
    func stop() {
        for c in constraints {
            manager.stopRangingBeacons(satisfying: c)
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            start()
        default:
            stop()
            beacons.removeAll()
            map.removeAll()
        }
    }
    
    func locationManager(_ manager: CLLocationManager,
                         didRange ranged: [CLBeacon],
                         satisfying constraint: CLBeaconIdentityConstraint) {
        let now = Date()
        
        for b in ranged {
            // Ensure this is one of our three UUIDs (it will be, because constraint)
            let uuid = b.uuid
            let major = UInt16(truncating: b.major)
            let minor = UInt16(truncating: b.minor)
            let key = "\(uuid.uuidString)-\(major)-\(minor)"
            
            // Preferred distance from CoreLocation (meters)
            let accuracy = b.accuracy // -1 if unknown
            let rssi = b.rssi
            
            // Fallback estimate if accuracy is invalid
            let fallback = (accuracy > 0)
                ? accuracy
                : BeaconRanger.estimateDistanceFromRSSI(rssi: rssi, txPowerAt1m: -59, pathLoss: 2.0)
            
            if var existing = map[key] {
                let newDistance = fallback
                let smoothed = (alpha * newDistance) + ((1 - alpha) * existing.smoothedDistance)
                existing.rawDistance = accuracy
                existing.smoothedDistance = smoothed
                existing.rssi = rssi
                existing.proximity = b.proximity
                existing.lastSeen = now
                map[key] = existing
            } else {
                let initial = max(fallback, 0.01)
                map[key] = TrackedBeacon(
                    id: key,
                    uuid: uuid,
                    major: major,
                    minor: minor,
                    rssi: rssi,
                    rawDistance: accuracy,
                    smoothedDistance: initial,
                    proximity: b.proximity,
                    lastSeen: now
                )
            }
        }
        
        // Prune entries for this UUID that weren’t seen in this pass (older than ~5s)
        let cutoff = now.addingTimeInterval(-5)
        map = map.filter { _, v in v.lastSeen >= cutoff }
        
        // Publish sorted by UUID then distance
        let snapshot = map.values
            .sorted { lhs, rhs in
                if lhs.uuid == rhs.uuid {
                    return lhs.smoothedDistance < rhs.smoothedDistance
                }
                return lhs.uuid.uuidString < rhs.uuid.uuidString
            }
        
        if snapshot != beacons { beacons = snapshot }
    }
    
    // If ranging fails for a constraint (e.g., hardware issues)
    func locationManager(_ manager: CLLocationManager, rangingBeaconsDidFailFor constraint: CLBeaconIdentityConstraint, withError error: Error) {
        print("Ranging failed for \(constraint.uuid): \(error.localizedDescription)")
    }
    
    // Basic path-loss model (coarse). txPowerAt1m is the measured power at 1 m (dBm).
    private static func estimateDistanceFromRSSI(rssi: Int, txPowerAt1m: Int = -59, pathLoss n: Double = 2.0) -> Double {
        guard rssi != 0, n > 0 else { return -1 }
        let ratio = Double(txPowerAt1m - rssi) / (10.0 * n)
        return pow(10.0, ratio)
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var ranger = BeaconRanger()
    
    var body: some View {
        NavigationView {
            List {
                Section("Your iBeacons") {
                    ForEach(ranger.beacons) { b in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shortUUID(b.uuid))
                                    .font(.headline)
                                Text("Major \(b.major) • Minor \(b.minor)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(String(format: "%.2f m", b.smoothedDistance))
                                    .monospaced()
                                    .font(.headline)
                                HStack(spacing: 8) {
                                    Text("\(b.rssi) dBm").monospaced().font(.caption)
                                    Text(proxLabel(b.proximity)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("iBeacon Distance")
            .overlay {
                if ranger.beacons.isEmpty {
                    ContentUnavailableView(
                        "Ranging…",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Make sure your three beacons are powered and nearby.")
                    )
                }
            }
            .onAppear { ranger.start() }
            .onDisappear { ranger.stop() }
        }
    }
    
    private func shortUUID(_ uuid: UUID) -> String {
        let s = uuid.uuidString
        return s.prefix(8) + "…" + s.suffix(4)
    }
    private func proxLabel(_ p: CLProximity) -> String {
        switch p {
        case .immediate: return "Immediate"
        case .near:      return "Near"
        case .far:       return "Far"
        default:         return "Unknown"
        }
    }
}

#Preview { ContentView() }
