# Rakiy Godot Addon

Connect Godot 4 to the [Rakiy](https://mineperial.com) relay and lobby service over WebSocket. Rakiy is by [Mineperial](https://mineperial.com).

> **This addon is in heavy early development.** The API and behavior may change; use at your own risk and expect breaking changes.

## Installation

1. Copy the `addons/rakiy` folder into your project's `addons/` directory.
2. Enable the addon: **Project → Project Settings → Plugins** and enable "Rakiy".
3. Add the client as an Autoload: **Project → Project Settings → Autoload**, add `RakiyClient` with path `res://addons/rakiy/rakiy_client.gd`.

See [addons/rakiy/README.md](addons/rakiy/README.md) for full installation, Autoload setup, API summary, and demo.

## Requirements

- Godot 4.x
- A running Rakiy server (local or hosted)
