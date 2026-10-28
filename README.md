# MouseAssist

A small macOS menu bar utility that does two things:

1. **Reverses the mouse wheel.** Only vertical scrolling from a regular mouse wheel is reversed;
   trackpads and Magic Mouse keep the system direction.
2. **Right-button drag gestures:**

   | Gesture | System shortcut it fires |
   |---|---|
   | Drag up | Mission Control (⌃↑) |
   | Drag down | Application windows (⌃↓) |
   | Drag left / right | Move one Space left / right (⌃← / ⌃→) |

   Each direction can be switched, from the menu, to another macOS system shortcut from a fixed list:
   Mission Control, Application Windows, Show Desktop, Move Left/Right a Space, Move Focus to Next
   Window, Show Spotlight Search, Turn Dock Hiding On/Off, Switch to Desktop 1–9, or nothing.

   By default a gesture fires as soon as the drag covers 40 points in a clear direction; the rest of
   that drag is ignored. The menu can switch it to fire on release instead, and set the distance
   (20–80 points). Releasing before the distance is reached counts as a normal right click, so context
   menus still work (they open on release). When a Move Left/Right a Space gesture has no Space left
   to go to, that edge of the screen glows briefly.

Each feature, plus Launch at Login (off by default), can be toggled from the menu bar icon.
The interface follows the system language (English and Simplified Chinese).

## Build and install

Only source code is published; there are no prebuilt binaries. You need macOS 13 or later and the
Xcode command line tools.

```bash
xcode-select --install   # if not installed yet
git clone https://github.com/TerrestrisYE/MouseAssist.git
cd MouseAssist
./build.sh               # build, sign, copy to /Applications and launch
```

- `./build.sh --no-install` only builds `build/MouseAssist.app`.
- On first launch, enable MouseAssist under System Settings → Privacy & Security → Accessibility.
- Signing: if your keychain has an Apple Development certificate, it is used and the Accessibility
  grant survives rebuilds. Otherwise the app is signed ad hoc and has to be approved again after every
  build. Pick a certificate explicitly with `SIGN_ID="certificate name" ./build.sh`.

## Known limitations

- Gestures only send each system shortcut's macOS **default** key. If you turned the shortcut off or
  bound it to another key in System Settings, the gesture does nothing rather than typing a stray key
  into the frontmost app; the menu marks such shortcuts. Switch to Desktop 1–9 is off by default in
  macOS and has to be turned on under Keyboard Shortcuts → Mission Control first.
- Arbitrary key combinations cannot be assigned, by design (see SECURITY.md).
- macOS ignores ⌃↓ in fullscreen apps, so dragging down has no effect there.
- While Right-Drag Gestures is on, every right-button drag is taken over, so apps that use right-drag
  themselves (3D and CAD tools, some games, browser mouse-gesture extensions) no longer receive it.
  Pressing the right button, holding, and releasing over a context menu item does not work either,
  because the context menu only opens on release. Turn the feature off from the menu when you need either.
- Detecting the last Space uses a private, read-only macOS Spaces call. If a future macOS changes it,
  the edge glow stops appearing; switching itself is unaffected.
- Horizontal scrolling is never reversed.

## Security

See [SECURITY.md](SECURITY.md) for the design rules and the permissions involved.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): you may use, modify and redistribute it for any
noncommercial purpose. This is a source-available license, not an OSI-approved open source license.
