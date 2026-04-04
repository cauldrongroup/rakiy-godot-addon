# Rakiy Godot Addon

Connect Godot 4 to the [Rakiy](https://mineperial.com) relay and lobby service over WebSocket. Rakiy is by [Mineperial](https://mineperial.com).

> **This addon is in heavy early development.** The API and behavior may change; use at your own risk and expect breaking changes.

## Installation

1. Copy the `addons/rakiy` folder into your project's `addons/` directory.
2. Enable the addon: **Project → Project Settings → Plugins** and enable **Rakiy** (provides **Project → Tools → Download / update WebRTC native** for the official [webrtc-native](https://github.com/godotengine/webrtc-native) GDExtension).
3. Add **one** Autoload: **Project → Project Settings → Autoload** → **`RakiyClient`** → `res://addons/rakiy/rakiy_client.gd`. Do not register the same script twice.

See [addons/rakiy/README.md](addons/rakiy/README.md) for WebRTC setup, send path, P2P reconnect behavior, and the full API summary.

## Requirements

- Godot 4.x
- A running Rakiy server (local or hosted)
- For **native P2P**: a Godot build with WebRTC **or** the webrtc-native GDExtension (see add-on README)
