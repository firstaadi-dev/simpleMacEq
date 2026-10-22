
extension AppState {
    func setGraphTestAppEQEnabled(_ enabled: Bool) {
        settings.appEQEnabled["test.player"] = enabled
    }

    func prepareGraphRecoveryTest(outputUID: String) {
        // Keep these fixture preferences in memory; never save test gains or routes.
        cancellables.removeAll()
        settings = AppSettings()
        settings.appVolumes["test.player"] = 1.5
        settings.appEQEnabled["test.player"] = true
        settings.appEQBands["test.player"] = [0, 0, 3, 0, 0, 0, 0, 0, 0, 0]
        settings.appOutputDeviceUID["test.player"] = outputUID
        volumeBoostEnabled = true
        eqEnabled = true
        bands = Band.defaultBands()
        bands[3].gain = 4
    }
}
