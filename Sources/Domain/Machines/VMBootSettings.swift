import Foundation

/// Derives one boot snapshot without changing persisted preferences or consulting UI objects.
enum VMBootSettings {
    static func make(preferences: VMSettings, distribution: GuestDistribution, hostAspectRatio: Double) throws
        -> VMSettings
    {
        if distribution == .windows {
            var snapshot = preferences
            snapshot.displayWidth = 1024
            snapshot.displayHeight = 768
            snapshot.keepHostAspectRatio = false
            return snapshot
        }
        guard preferences.keepHostAspectRatio == true else { return preferences }

        let options = VMDisplayPresets.resolutions(hostAspectRatio: hostAspectRatio)
        guard
            let selected = options.min(by: {
                abs($0.width - (preferences.displayWidth ?? 1920))
                    < abs($1.width - (preferences.displayWidth ?? 1920))
            })
        else {
            throw settingsError(
                "This host display’s aspect ratio has no supported resolution. Disable aspect ratio matching in Preferences."
            )
        }

        var snapshot = preferences
        snapshot.displayWidth = selected.width
        snapshot.displayHeight = selected.height
        return snapshot
    }
}
