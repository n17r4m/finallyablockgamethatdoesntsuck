#!/usr/bin/env bash
# Builds the Rust rules as a Godot extension into ext/bin/, which isn't committed.
#   tools/build_rust_ext.sh linux | android | web
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p ext/bin

case "${1:-linux}" in
linux)
	cargo build --release --manifest-path rust/Cargo.toml -p fbg-godot
	cp rust/target/release/libfbg_godot.so ext/bin/libfbg_godot.linux.x86_64.so
	;;
android)
	: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
	ndk="$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -n 1)"
	bin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
	export CLANG_PATH="$bin/clang"
	export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$bin/aarch64-linux-android24-clang"
	export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$bin/x86_64-linux-android24-clang"
	for pair in aarch64-linux-android:arm64 x86_64-linux-android:x86_64; do
		cargo build --release --manifest-path rust/Cargo.toml -p fbg-godot --target "${pair%%:*}"
		cp "rust/target/${pair%%:*}/release/libfbg_godot.so" "ext/bin/libfbg_godot.android.${pair##*:}.so"
	done
	;;
web)
	# Needs nightly Rust with rust-src and the wasm32-unknown-emscripten target, and emcc on
	# PATH. Single-threaded, so it runs without the headers threaded web builds require.
	export GODOT4_BIN="${GODOT:-$(realpath ../Godot/Godot_v4.7.2-stable_linux.x86_64)}"
	export RUSTFLAGS="-C link-args=-sSIDE_MODULE=2 -C llvm-args=-enable-emscripten-cxx-exceptions=0 -Z default-visibility=hidden -Z link-native-libraries=no -C panic=abort"
	cargo +nightly build --release --manifest-path rust/Cargo.toml -p fbg-godot \
		-Zbuild-std=std,panic_abort --target wasm32-unknown-emscripten
	cp rust/target/wasm32-unknown-emscripten/release/fbg_godot.wasm ext/bin/fbg_godot.web.nothreads.wasm
	;;
*)
	echo "usage: $0 linux | android | web" >&2
	exit 2
	;;
esac
ls -l ext/bin
