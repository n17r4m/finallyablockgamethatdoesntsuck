# Where the Rust rules run

`rust/godot` is a thin Godot extension over `rust/sim`, exposed to GDScript as `RustSim`. The
game doesn't play on it yet. This page records where it has been proven to work, and how to
check a new platform.

## Results

Each row ran `tests/engine_probe.gd` on Godot 4.7.2: all 47 recorded games through both
implementations, new games compared tick by tick, 200 damaged replays refused, and timings on
four recorded CPU games. Timings are per tick for both boards.

| Platform | Result | Rust | GDScript | Worst 192-tick rollback, Rust / GDScript |
|---|---|---|---|---|
| Linux x86-64, debug | Pass | 0.91 µs | 20.55 µs | 0.20 / 4.08 ms |
| Android x86-64, emulator, debug | Pass | 0.94 µs | 23.21 µs | 0.20 / 4.29 ms |
| Android arm64, translated on the emulator, debug | Pass, timings meaningless | | | |
| Web, Chromium, release, no threads | Pass | 0.44 µs | 26.83 µs | 0.20 / 5.90 ms |
| Web, Chromium, debug, no threads | Pass | 0.45 µs | 34.73 µs | 0.10 / 6.30 ms |

The browser's clock only ticks every 0.1 ms, so web's single-rollback figures are coarse.

Not tested:

- **A real phone.** Nothing here measures phone speed, heat or battery.
- **iOS.** Building it needs a Mac. No part of it has been tried.
- **Firefox and Safari.** godot-rust's guide says Firefox supports extensions less fully.
- **Threaded web builds.** Only the single-threaded build exists.
- **Windows and macOS desktop.** `ext/fbg_sim.gdextension` lists no library for them yet.

Rust running twice as fast as wasm as it does natively is real, and unexplained: `bench_sim`
under Node, with no Godot involved, also measures 0.43 µs. `panic=abort` isn't the reason.

Extension support adds about 1 MB to a gzipped web download (10.1 to 11.1 MB of engine), plus
0.14 MB for the Rust code itself.

## Building

`tools/build_rust_ext.sh linux | android | web` writes to `ext/bin/`, which isn't committed.
Without a library the game and its tests still run, and only `test_rust_bridge` fails.

- **Android** needs `rustup target add aarch64-linux-android x86_64-linux-android` and an NDK
  under `ANDROID_HOME`.
- **Web** needs a nightly toolchain with `rust-src` and `wasm32-unknown-emscripten`, `emcc` on
  `PATH`, `LIBCLANG_PATH` pointing at a libclang (emsdk's `upstream/lib` was used), and export
  templates that include `web_dlink_nothreads`. Emscripten 4.0.7 worked against templates
  built with 4.0.20.

These are the parts most likely to surprise someone:

- Android uses the bindings' `experimental-threads` feature. Godot sets extensions up across
  two threads there, and the default single-threaded mode panics during startup.
- Web uses godot 0.5.5 with bindings generated from the Godot binary, since the prebuilt ones
  assume 64-bit. Everything else uses 0.4.5, because 0.5.5 needs Rust 1.94. Version 0.4.5
  can't read the API of Godot 4.6 or 4.7, so web can't simply use it too.
- Panics abort on web. Elsewhere, a panic outside the bindings' guards aborts too. `rust/sim`
  is tested not to panic on any legal game or any damaged replay.

## Running the probe

Export the "Android Probe" or "Web Probe" preset. Those builds boot straight into the probe
and print to the screen and the log (`adb logcat -s godot`, or the browser console). On
desktop: `godot --headless --path . -s tests/test_rust_bridge.gd`.

Android exports need `export/android/java_sdk_path` in Godot's editor settings and a debug key,
which can be set with `GODOT_ANDROID_KEYSTORE_DEBUG_PATH`, `_USER` and `_PASSWORD`.

Web pages need to be in view. A hidden browser tab gets very few frames and the probe crawls.
