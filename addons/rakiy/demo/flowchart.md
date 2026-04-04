# Rakiy demo — UI / UX flowchart

Technical demo for developers: **Connect → Lobby → 3D arena** with optional messaging lab. Desktop, mouse + keyboard. The HUD is **one floating tabbed console** (no full-width header strip) so the viewport stays clean.

## Screen regions (always)

| Region | Role |
|--------|------|
| **World (viewport)** | Full window behind UI. Arena + mouse capture; only the floating card consumes pointer events over its area. |
| **Floating console card** | Rounded panel anchored bottom-center: **status pill** (shrink-wrapped, top-right; wraps long errors) + **Connect** \| **Lobby** \| **Lab** tabs. Lobby and Lab stay **disabled** until handshake. |
| **Connect tab** | Title + one-line controls hint + URL / name / buttons — no tutorial paragraphs. |

## Flow (menus, not a mega-panel)

```text
[Launch]
    |
    v
Tab: Connect — URL + name + buttons
    |
    v
[Handshake OK] ───────────────────────► auto-switch to Tab: Lobby
    |
    +---- Tab: Lobby ---- create / join / refresh / roster / public list
    |
    +---- Tab: Lab ------ peer send + event log (optional debugging)
```

### Tab: **Connect**

- **Relay URL**, **Display name**, **Connect** / **Disconnect**.
- Fields locked while connecting or connected.

### Tab: **Lobby** (after handshake)

- Create / join / refresh, current lobby + **Copy ID**, **Players** list, **Public** list (scrollable).

### Tab: **Lab** (after handshake)

- Peer **Send** row + **Binary** + **Event log**.

## Visual system (cohesive)

| Element | Meaning |
|---------|---------|
| **Cyan accent** | Section labels, primary actions. |
| **Muted captions** | Field labels only; tabs imply the flow. |
| **Primary buttons** | Teal — forward actions (Connect, Create, Join, Send). |
| **Secondary buttons** | Neutral — Disconnect, Leave, Refresh, Copy ID. |
| **Disabled tabs** | Lobby & Lab until handshake — progressive disclosure. |

## Motion / feedback

- Tab bar shows only one screen of controls at a time.
- Successful handshake moves the user to the **Lobby** tab automatically (`go_to_lobby_tab()`).
- Losing the session (`not handshaken`) snaps navigation back to **Connect** (`apply_connection_state`).

## Revision

Update this file when adding new surfaces (e.g. settings, dedicated server browser).
