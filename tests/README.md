# Audio regression checks

Run `bash tests/run.sh` on macOS with Swift Command Line Tools. The runner uses a
temporary directory and adds test extensions to copies of the actual audio source
files, so private graph state can be tested without changing the app's API. It does
not start capture taps, change the system output, or write hardware volume.

Covered automatically:

- A configuration notification from an owned engine schedules a rebuild even when
  the output device ID and active process list stay unchanged.
- Notifications from other engines are ignored; bursts rebuild once on the main
  run loop, outside Core Audio's notification callback.
- Output changes rebuild after `@Published` commits the new value.
- Stopped engines and missing taps retry without a process-list change.
- Teardown cancels recovery subscriptions and timers.
- Selecting an output reads that device's hardware volume (when readable).
- Ring overflow preserves whole frames and channel order; reads zero-pad underruns.
  Repeated wraparound is checked for mono, stereo, and six channels.
- Toggling App EQ on a running graph keeps audio audible, follows master EQ when
  disabled, and bypasses it when enabled. Master bypass preserves audio, and two
  apps retain separate mixer inputs through startup and mode changes.
- A real `AVAudioEngine` renders nonzero, finite PCM after repeated 48 kHz/stereo ↔
  16 kHz/mono rebuilds, through both global EQ and per-app EQ. The test supplies
  in-memory capture samples and offline destinations; lifecycle, source creation,
  reconnection, EQ/boost/route restoration, and failed-capture retry use the actual
  controller. No live capture or hardware output is started.

## Reporter validation: Bluetooth + Discord

This remains unverified without the affected headset. Synthetic notifications and
offline rendering prove controller recovery and sample output, not Bluetooth
negotiation, live process capture, or audible playback during a call.

1. Build and run the changed app. Connect the affected Bluetooth headphones and
   select them as the macOS output. Enable EQ and play continuous music.
2. In Discord, select the headset microphone and join a voice channel/call.
3. Confirm music and Discord remain audible, allowing a short interruption during
   the profile change, without relaunching the EQ app.
4. Leave and rejoin the call at least five times. Confirm playback returns in both
   directions and EQ, per-app volume/mute, and output choices remain as configured.
5. Repeat with per-app output pinned to the headphones, then disconnect/reconnect
   the headphones and verify fallback and restoration.
6. Repeat with the Mac/external microphone selected and with EQ bypassed.

Capture macOS version, app build/commit, headset model if known, Discord input/output
choices, EQ status/error text, and whether the input/output meters move if silence
still occurs. Reduced Bluetooth call quality is separate from persistent silence.
