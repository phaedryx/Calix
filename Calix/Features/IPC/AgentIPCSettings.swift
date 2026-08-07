// AgentIPCSettings.swift
// Calix
//
// UserDefaults-backed store for which IPCAgents participate in "Enable
// AI Agent IPC". Same SettingsStore-backed pattern as CockpitSettings/
// CommandTrackingSettings. Defaults ON for every agent -- shipping this
// must not change behavior for an existing user until they actively
// uncheck something in Settings > Agents.
//
// Gates IPCConfigManager.enableIPC only. disableIPC always removes
// every agent's config regardless of this preference -- see that
// type's own header comment for the truth table and why (uncheck must
// always clean up, or a disabled agent's config could orphan a
// calix-ipc entry pointing at a dead port).

import Foundation

struct AgentIPCSettings: Sendable {

    private static let settingsStore = SettingsStore()

    static func _testUseSuite(named name: String) {
        settingsStore.testUseSuite(named: name)
    }

    static func _testTeardownSuite(named name: String) {
        settingsStore.testTeardownSuite(named: name)
    }

    private static var store: UserDefaults {
        settingsStore.store
    }

    private static func key(for agent: IPCAgent) -> String {
        "calix.ipc.\(agent.rawValue)Enabled"
    }

    /// Documented default when the key has never been written: `installed`
    /// (same `object(forKey:) == nil` absence check as
    /// CommandTrackingSettings.trackingEnabled) -- an agent that isn't on
    /// this machine has nothing meaningful to enable, so it defaults off;
    /// an installed one defaults on, preserving pre-existing behavior for
    /// every agent a user already has. `installed` defaults to `true` so
    /// callers that don't know or care about install status (or a test
    /// suite that can't assume any particular filesystem state) see the
    /// original always-true-when-unset behavior.
    static func isEnabled(_ agent: IPCAgent, installed: Bool = true) -> Bool {
        let key = key(for: agent)
        if store.object(forKey: key) == nil {
            return installed
        }
        return store.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, for agent: IPCAgent) {
        store.set(enabled, forKey: key(for: agent))
    }
}
