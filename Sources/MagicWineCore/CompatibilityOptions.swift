import Foundation

/// Bottle-wide launch switches. Metadata only: changed with
/// `BottleStore.setCompatibility` while programs run; used by later launches.
public struct CompatibilityOptions: Codable, Hashable, Sendable {
    public enum WineDebug: String, Codable, CaseIterable, Sendable {
        /// `WINEDEBUG=fixme-all`: hides unimplemented-function noise, keeps `err:` lines.
        case quiet
        /// No `WINEDEBUG`: Wine's own default (errors and fixme messages).
        case wineDefault = "default"

        public var displayName: String {
            switch self {
            case .quiet: "Quiet (errors only)"
            case .wineDefault: "Wine default (errors and fixme)"
            }
        }
    }

    public enum DXVKHUD: String, Codable, CaseIterable, Sendable {
        case fps
        case detailed

        public var displayName: String {
            switch self {
            case .fps: "Frame rate only"
            case .detailed: "Detailed"
            }
        }

        /// `DXVK_HUD` value used when the bottle's graphics HUD is on.
        public var value: String {
            switch self {
            case .fps: "fps"
            case .detailed: "version,api,devinfo,fps,frametimes"
            }
        }
    }

    /// `ROSETTA_ADVERTISE_AVX=1`; only effective for x86_64 Wine under Rosetta 2 on
    /// macOS 15 or later (see `WineRuntime.rosettaAVXAvailability`).
    public var advertiseAVX: Bool
    public var wineDebug: WineDebug
    public var dxvkHUD: DXVKHUD

    public init(advertiseAVX: Bool = false, wineDebug: WineDebug = .quiet, dxvkHUD: DXVKHUD = .detailed) {
        self.advertiseAVX = advertiseAVX
        self.wineDebug = wineDebug
        self.dxvkHUD = dxvkHUD
    }

    private enum CodingKeys: String, CodingKey {
        case advertiseAVX, wineDebug, dxvkHUD
    }

    /// Missing keys take their defaults, so newer switches decode in older records.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        advertiseAVX = try container.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? false
        wineDebug = try container.decodeIfPresent(WineDebug.self, forKey: .wineDebug) ?? .quiet
        dxvkHUD = try container.decodeIfPresent(DXVKHUD.self, forKey: .dxvkHUD) ?? .detailed
    }
}

/// Whether Rosetta can honor `ROSETTA_ADVERTISE_AVX` for a runtime on this Mac.
public enum RosettaAVXAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)
}
