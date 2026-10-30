import Virtualization

/// Routes guest playback to the host default output without opening a microphone.
@MainActor
enum VMAudioConfiguration {
    static func devices(resources: Resources) -> [VZAudioDeviceConfiguration] {
        guard resources.audioOutputEnabled != false else { return [] }
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [output]
        return [sound]
    }
}
