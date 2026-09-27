# HorizonsOS1

A Hyprland + Noctalia desktop setup for Arch Linux (Wayland), with Dunst notifications and Swappy screenshots. Theme: "Golden Gate" — frosted glass surfaces with a warm gold accent.

## Why?
The purpose of this repo is purely to recovery my workflow in shortest time possible, especially when I break things. Hyprland and Noctalia configs were handwritten, for the most part, through their respective wikis. The Noctalia GoldenGate palletes is all AI, along with dunst config. Some entries in hyprland.lua wont work because the apps are not set up.


**Jump to:** [Install](#install) · [What the installer does](#what-installsh-does) · [Going back](#going-back-to-your-previous-setup) · [Notifications](#notifications-dunst-vs-noctalia) · [Keybinds](#keybinds)

## What's included

| Folder             | Installs to            | Contents                                            |
|--------------------|------------------------|-----------------------------------------------------|
| `config/hypr`      | `~/.config/hypr`       | `hyprland.lua` (Lua config), `monitors.lua` |
| `config/noctalia`  | `~/.config/noctalia`   | `config.toml`, `palettes/GoldenGate.json`           |
| `config/dunst`     | `~/.config/dunst`      | `dunstrc` (iOS-style bubble notifications)          |
| `config/swappy`    | `~/.config/swappy`     | `config` (saves to `~/Pictures/Screenshots`)        |

The Hyprland config uses the Lua format introduced in Hyprland 0.55, and the Noctalia config targets Noctalia v5+ (`config.toml`).

## Requirements
You already have Hyprland and Noctalia Desktop Shell v5+ at this point, anyway...I'll refine this later
```bash
sudo pacman -S --needed hyprland noctalia dunst libnotify swappy grim slurp wl-clipboard \
    kitty nautilus wofi hyprpaper hyprpolkitagent udiskie blueman \
    brightnessctl playerctl wireplumber flatpak
```

[Noctalia](https://docs.noctalia.dev/noctalia/) (pacman). The Hyprland config also launches Zen Browser, Mission Center and EasyEffects via Flatpak, and ProtonVPN — remove those lines from `hyprland.lua` if you don't use them.

What the extra packages are for: `wl-clipboard` (screenshot-to-clipboard), `brightnessctl` (brightness keys), `playerctl` (media keys), `wireplumber` (provides `wpctl` for volume keys). Optional: `hyprshutdown` — `Super+M` uses it if installed, otherwise it exits Hyprland directly.

## Install

```bash
git clone https://github.com/HorizonsMW/HorizonsOS1.git
cd HorizonsOS1
./install.sh
```

**Run it as your normal user — do not use `sudo`.** Everything lives in your own home directory, and the installer refuses to run as root so nothing ends up owned by root or in `/root`.

Preview first if you like:

```bash
./install.sh --dry-run
```

Options:

| Flag              | Effect                                                                  |
|-------------------|-------------------------------------------------------------------------|
| `-y`, `--yes`     | Overwrite without prompting (backups are still made)                    |
| `-n`, `--dry-run` | Print what would happen, change nothing                                 |
| `--no-reload`     | Install the files only; don't reload or restart anything                |
| `-h`, `--help`    | Show help                                                               |

Environment override: if Noctalia isn't auto-detected, tell the installer how to start it, e.g. `NOCTALIA_LAUNCH="noctalia" ./install.sh`.

## What `install.sh` does

1. **Shows the banner** — name, author and version.
2. **Safety checks** — refuses to run as root, and confirms `$HOME` and the repo's `config/` folder exist.
3. **Makes sure `~/.config` exists** — creates it (mode `0700`) if it's missing.
4. **Checks dependencies** — warns (never blocks) if `hyprctl`, Noctalia, `dunst` or `swappy` aren't found in your `PATH`.
5. **Deploys each config folder** — `hypr`, `noctalia`, `dunst`, `swappy`, one at a time:
   1. Skips a folder that's missing or empty in the repo.
   2. If `~/.config/<folder>` does **not** exist, creates it and copies the config in.
   3. If it **does** exist:
      - Checks you have write permission there. If not (for example the folder is root-owned from an earlier `sudo` run) it tells you exactly which path and the `chown` command to fix it, skips that folder, and carries on with the rest.
      - **Asks whether to overwrite** (skipped with `-y`). Answer `n` to leave that folder alone.
      - **Backs up** each file that is about to be replaced by renaming it to `<file>.bak` (or `<file>.bak.<timestamp>` if a `.bak` already exists). Files that are already identical to the repo copy are not backed up.
      - **Copies** the repo files in. Files in your folder that aren't part of this repo are left untouched.
      - If the copy fails, the backups are put back automatically.
   4. If `~/.config/<folder>` is a symlink (for example into a dotfiles manager) it is skipped rather than modified.
6. **Reloads the running session** (only if a live Hyprland session is found; otherwise the configs apply at next login):
   - **Hyprland** — `hyprctl reload` (a reload, not a restart, so your session stays alive), then checks `hyprctl configerrors` and prints any errors.
   - **Noctalia** — restarted (via systemd if you run it as a user service, otherwise killed and relaunched) and checked that it came back up.
   - **Dunst** — reloaded in place with `dunstctl reload`, or restarted if that isn't possible.
   - **Swappy** — has no daemon; the new config is read the next time you launch it.
   - Sends a test notification when done.
7. **Prints a summary** — what was installed, what (if anything) failed, and how many originals were backed up. The exit code is non-zero if any folder failed. Re-running is always safe.

## Going back to your previous setup

The installer never deletes anything: every file it replaces is kept next to the new one as `<file>.bak`.

### Before you install (recommended)

For a rollback that doesn't depend on anything below, take a snapshot first:

```bash
mkdir -p ~/config-backup
cp -a ~/.config/hypr ~/.config/noctalia ~/.config/dunst ~/.config/swappy ~/config-backup/ 2>/dev/null || true
```

(Folders you don't have yet are simply skipped.)

### Restore a single file

```bash
mv ~/.config/dunst/dunstrc.bak ~/.config/dunst/dunstrc
```

### Restore everything

Run this from the cloned repo. For every file HorizonsOS1 ships, it puts your original back if one was backed up, and removes the file if it didn't exist before:

```bash
cd HorizonsOS1
for dir in hypr noctalia dunst swappy; do
  ( cd "config/$dir" && find . -type f -printf '%P\n' ) | while IFS= read -r f; do
    t="$HOME/.config/$dir/$f"
    if [[ -e "$t.bak" ]]; then mv -f -- "$t.bak" "$t"   # you had one before: put it back
    else rm -f -- "$t"                                   # HorizonsOS1 added it: remove it
    fi
  done
  find "$HOME/.config/$dir" -depth -type d -empty -delete 2>/dev/null || true   # tidy empty folders
done
```

Then apply it:

```bash
hyprctl reload
pkill noctalia; setsid -f noctalia    # only if you use Noctalia in your old setup
pkill dunst;    setsid -f dunst       # only if you use Dunst in your old setup
```

Things to know:

- **Old `hyprland.conf` users:** if you had the classic `~/.config/hypr/hyprland.conf` and no `hyprland.lua`, your old file is still there after installing — but Hyprland loads `hyprland.lua` *instead* of `hyprland.conf` whenever a `.lua` exists. The restore snippet above removes the installed `hyprland.lua`, which hands control back to your old `hyprland.conf`.
- **Timestamped backups** (`<file>.bak.<time>`) are made whenever a `<file>.bak` already exists. That happens if you edited an installed file and re-ran the installer (the timestamped copy is your edited version), or if you already had an unrelated `<file>.bak` before installing (then your original is the timestamped one). Normally `.bak` is the copy from before your *first* install — check with `ls -l` if unsure, and delete leftovers with `find ~/.config -name '*.bak.*'` once you're happy.
- **Edits made after installing are lost** by the snippet (it restores originals over the installed files). Copy anything you want to keep first.
- The snippet expects backups made by an unmodified install. If you hand-edited installed files and re-ran the installer, review the `.bak` files manually instead.

## Notifications: Dunst vs Noctalia

**Dunst currently handles all notifications. Noctalia's notification daemon is turned off.** Only one program can own the notification service (`org.freedesktop.Notifications`) at a time, so run one or the other, never both.

Where each piece lives:

| What                                | File                              | Setting                                              |
|-------------------------------------|-----------------------------------|------------------------------------------------------|
| Noctalia notification daemon        | `~/.config/noctalia/config.toml`  | `[notification]` → `enable_daemon = false`           |
| Noctalia bar notification widget    | `~/.config/noctalia/config.toml`  | `[bar.default]` → `end = [...]` → `## "notifications",` (commented out) |
| Dunst autostart                     | `~/.config/hypr/hyprland.lua`     | `hl.exec_cmd("dunst &")` in the `hyprland.start` block |
| Dunst appearance                    | `~/.config/dunst/dunstrc`         | bubble style, colors, position                       |

### Switch to Noctalia notifications (and turn Dunst off)

1. In `~/.config/noctalia/config.toml`, under `[notification]`, set:
   ```toml
   enable_daemon = true
   ```
2. Optional — show the notification bell in the bar: in `[bar.default]`, in the `end = [...]` list, change `## "notifications",` to `"notifications",`.
3. In `~/.config/hypr/hyprland.lua`, comment out the Dunst autostart line so it doesn't come back at next login:
   ```lua
   -- hl.exec_cmd("dunst &")
   ```
4. Apply it now, without logging out. **Stop Dunst first** so Noctalia can claim the notification service:
   ```bash
   pkill dunst
   hyprctl reload
   pkill noctalia; setsid -f noctalia
   notify-send "Test" "Now handled by Noctalia"
   ```
5. Verify who owns notifications:
   ```bash
   busctl --user list | grep org.freedesktop.Notifications
   ```
   The process column should say `noctalia`.

Blur for Noctalia's notification toasts is already covered by the layer rule in `hyprland.lua`. The separate Dunst layer rule (`dunst-bubbles`) becomes unused and is harmless.

**Dunst keeps coming back?** The `dunst` package can be started on demand by D-Bus. Stop that with `systemctl --user mask dunst.service`, or remove it entirely with `sudo pacman -Rns dunst`.

**Re-running the installer:** it also installs and restarts Dunst. If you've moved to Noctalia notifications, remove `dunst` from the `CONFIGS=(...)` line at the top of `install.sh` (or delete `config/dunst/`) so a re-run doesn't start it again.

### Switch back to Dunst

1. In `config.toml`, set `enable_daemon = false` (and re-comment the `"notifications"` bar entry if you enabled it).
2. In `hyprland.lua`, restore `hl.exec_cmd("dunst &")`.
3. Restart in this order — Noctalia first, so it lets go of the notification service, then Dunst:
   ```bash
   pkill noctalia; setsid -f noctalia
   setsid -f dunst
   ```

## Keybinds

Defined in `config/hypr/hyprland.lua`. **`Super`** is the main modifier (the Windows / Command key).

### Launchers and apps

| Keys                    | Action                                             |
|-------------------------|----------------------------------------------------|
| `Super + Return`        | Open terminal (kitty)                              |
| `Super + E`             | Open file manager (Nautilus)                       |
| `Super + Z`             | Open Zen Browser (Flatpak)                         |
| `Super + R`             | Application launcher (wofi `drun`)                 |
| `Super + Space`         | Noctalia app launcher                              |
| `Super + V`             | Noctalia clipboard history                         |
| `Super + ,`             | Noctalia settings                                  |
| `Alt + Tab`             | Noctalia window switcher                           |
| `Ctrl + Shift + Esc`    | System monitor (Mission Center)                    |

### Windows

| Keys                          | Action                                                      |
|-------------------------------|-------------------------------------------------------------|
| `Super + Q`                   | Close the active window                                     |
| `Super + T`                   | Toggle floating for the active window                       |
| `Super + P`                   | Toggle pseudo-tiling (dwindle)                              |
| `Super + J`                   | Toggle split direction (dwindle)                            |
| `Super + ←` `→` `↑` `↓`       | Move focus left / right / up / down                         |
| `Super + Tab`                 | Cycle to the next window and raise it (handy with floating windows) |
| `Super + Left-click drag`     | Move a window                                               |
| `Super + Right-click drag`    | Resize a window                                             |

### Workspaces

| Keys                          | Action                                                      |
|-------------------------------|-------------------------------------------------------------|
| `Super + 1` … `9`, `0`        | Switch to workspace 1–9; `0` goes to workspace 10           |
| `Super + Shift + 1` … `0`     | Move the active window to that workspace                    |
| `Super + Scroll down / up`    | Next / previous existing workspace                          |
| 3-finger swipe left / right   | Switch workspace (touchpad)                                 |
| `Super + S`                   | Show / hide the scratchpad (special workspace `magic`)      |
| `Super + Shift + S`           | Send the active window to the scratchpad                    |

Workspaces 1–4 are persistent on `eDP-1`, named: 1 `web`, 2 `tasks`, 3 `code`, and 4 `game`. Workspaces 5 to 10 are created on demand.

### Screenshots

| Keys                | Action                                                                                   |
|---------------------|------------------------------------------------------------------------------------------|
| `Print`             | Select an area, then open it in Swappy to annotate and save                              |
| `Super + Print`     | Select an area (with dimensions shown), save it to `~/Pictures/Screenshots/screenshot-<date-time>.png` **and** copy it to the clipboard |

### Session and power

| Keys                        | Action                                                                |
|-----------------------------|-----------------------------------------------------------------------|
| `Super + L`                 | Lock the screen (Noctalia). Works even while already locked           |
| Close the laptop lid        | Lock and suspend (Noctalia)                                           |
| `Super + Power button`      | Noctalia power menu (lock, logout, suspend, reboot, shutdown)         |
| `Super + M`                 | **Exit Hyprland immediately — no confirmation.** Save your work first |

### Media and hardware keys

These also work on the lock screen, and volume/brightness repeat while held.

| Keys                                   | Action                                              |
|----------------------------------------|-----------------------------------------------------|
| `Volume Up` / `Volume Down`            | Output volume ±5% (volume is capped at 100%)        |
| `Mute`                                 | Toggle speaker mute                                 |
| `Mic Mute`                             | Toggle microphone mute                              |
| `Brightness Up` / `Brightness Down`    | Screen brightness ±5% (also drives Noctalia's brightness step and on-screen indicator) |
| `Play` / `Pause`                       | Play / pause the current player                     |
| `Next` / `Previous`                    | Next / previous track                               |

### Inside Noctalia panels

| Keys                       | Action                                                      |
|----------------------------|-------------------------------------------------------------|
| `↑` `↓` `←` `→`            | Navigate                                                    |
| `Tab` / `Shift + Tab`      | Next / previous tab                                         |
| `Return`, `Space`          | Confirm / activate                                          |
| `Esc`                      | Cancel / close                                              |
| `Delete`                   | Delete the selected item                                    |
| `Ctrl + C` / `Ctrl + S`    | Copy / save                                                 |
| `1` … `5` (power menu)     | Lock · Log out · Lock and suspend · Reboot · Shut down      |

## Notes

- `config/hypr/monitors.lua` is generated by nwg-displays for a 1920x1080 `eDP-1` panel. Regenerate it for your own monitors. The workspace rules and the Noctalia lock-screen widget are also pinned to `eDP-1`.
- For real glass blur on Noctalia, keep layer-shell blur enabled for the Noctalia namespace in Hyprland (already set in `hyprland.lua`).
- The Noctalia wallpaper folder in `config.toml` is set to `/home/horizons/Pictures/Wallpapers`. Change it to your own path.

## License

MIT