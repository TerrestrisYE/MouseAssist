# Security design

MouseAssist needs the Accessibility permission, and a bug in a tool like this affects input across the
whole system. The design goal is therefore that **the tool has no capability worth abusing**: someone
who forges a mouse gesture or edits its settings gets nothing more than "switch one Space".

## What it can and cannot do

| Area | MouseAssist |
|---|---|
| Permissions | Accessibility only. No Input Monitoring, Screen Recording, Full Disk Access or Automation (Apple Events) |
| Code signing | Hardened Runtime, no entitlements at all. Not sandboxed (event taps cannot be created inside the App Sandbox) |
| Event tap | One, at session level (`kCGSessionEventTap`), subscribed to exactly four event types: right mouse down, right mouse dragged, right mouse up, scroll wheel |
| Keyboard | The tap **never sees keyboard events** |
| Modifying events | Only the three vertical delta fields of scroll-wheel events |
| Holding back events | Only right-button events while a gesture may be in progress (see below) |
| Keys it sends | Only the macOS default keys of a fixed allowlist of system shortcuts, hard-coded in the app (Mission Control, Application Windows, Show Desktop, Move Left/Right a Space, Move Focus to Next Window, Show Spotlight Search, Turn Dock Hiding On/Off, Switch to Desktop 1–9) |
| Network | No networking code, no auto-update |
| Running commands or scripts | None (does not link NSTask, `system`, `posix_spawn` or NSAppleScript) |
| Settings | Three booleans, the trigger mode and gesture distance (each picked from a fixed list), and per direction the name of one allowlisted shortcut, in the app's own preferences domain. Unknown values fall back to the default. No import, export, sync or URL scheme |
| Private API | Read-only `CGSCopyManagedDisplaySpaces` to find the current Space; if it is unavailable, only the edge glow is lost |
| Logging | Debug level only: gesture direction and Space index. No coordinates, no frontmost app |
| Installation | Built locally and copied to `/Applications`. No installer scripts, no root daemons, no quarantine stripping |
| Launch at login | Off by default; turned on from the menu through `SMAppService`, so it shows up (and can be removed) under Login Items |

## Deliberate trade-offs

**Holding back right-button events.** A gesture recognizer that only listens (cannot intercept) lets the
app under the pointer receive the right mouse down, so its context menu opens and releasing after the drag
can pick a menu item such as "Move to Trash". MouseAssist therefore holds right-button events back while a
gesture may be in progress:

- released before the gesture distance (40 points by default) is reached: the original press and release
  are posted again unchanged, which is an ordinary right click;
- moved far enough: it is a gesture (fired during the drag or on release, per the Trigger setting), and
  that right click reaches no app.

Only the right button is involved. With Right-Drag Gestures turned off, right-button events pass straight
through.

**Gestures pick from an allowlist, never from arbitrary keys.** Each direction can be set to one system
shortcut from a list compiled into the app; the preferences only store which entry, by name. Every entry
is a navigation or view action that is easy to undo. Left out on purpose: screenshots and screen recording
(they would put screen contents where other programs can read them), accessibility toggles such as
VoiceOver, Services and app shortcuts (user-defined, may run scripts), input source switching, and
anything without a macOS default key. A program that edits MouseAssist's preferences can at most swap a
gesture for another harmless entry.

**Only default keys are sent; system settings are read for on/off only.** Before sending, MouseAssist
reads the system shortcut settings (`com.apple.symbolichotkeys`), but only to check that the shortcut is
enabled and still bound to its macOS default key. The key it sends is always the hard-coded default and is
never taken from any preferences file, so another program that edits those preferences cannot make
MouseAssist type arbitrary keys. If the shortcut is off or rebound, the gesture does nothing.

**Synthetic events are not filtered.** Another program with Accessibility access can forge a right-button
drag and trigger a gesture. This is accepted on purpose: a program able to post mouse events can post these
four shortcuts directly, so going through MouseAssist gains it nothing.

**The event tap runs on its own thread.** A stalled menu or overlay cannot slow down right clicks and
scrolling system-wide. If macOS disables the tap after a timeout, it is re-enabled immediately.

## Checking it yourself

After building, the claims above can be verified:

```bash
APP=build/MouseAssist.app
codesign -d --entitlements - "$APP"        # should print no entitlements
codesign -dv "$APP" 2>&1 | grep flags      # should include runtime
# The following should print nothing: no symbols for running commands,
# scripting, networking, raw HID, raw touch data or keychain access.
nm -u "$APP/Contents/MacOS/MouseAssist" \
  | grep -iE 'NSTask|_system$|posix_spawn|NSAppleScript|URLSession|socket|IOHID|MTDevice|SecItem|KeyboardSetUnicodeString'
```

While it runs, `CGGetEventTapList` shows MouseAssist's tap; its event mask should contain only bits 3, 4,
7 and 22 (right mouse down, right mouse up, right mouse dragged, scroll wheel).

## Reporting a problem

Please open a GitHub issue, or for anything sensitive, use the contact details on the maintainer's
GitHub profile.
