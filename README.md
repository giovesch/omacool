# omacool

Fan control for the [Omarchy](https://omarchy.org) Quattro bar.

Every fan and temperature sensor the kernel exposes through `hwmon`, in one
panel: presets, per-fan modes, and a curve you can drag.

- **Bar glyph** — the hottest sensor on the machine, turning urgent past the
  critical threshold. Scroll it to walk the presets without opening anything.
- **Presets** — Auto, Silent, Balanced, Perf, Max. One click retunes every
  controllable fan.
- **Per-fan control** — click a fan to expand it: hand it back to the firmware,
  pin it to a fixed duty cycle, or give it its own curve.
- **Curve editor** — drag the handles, double-click to add a point, right-click
  to remove one. A dashed marker shows where the machine is sitting right now,
  so you are tuning against live readings rather than guessing.
- **Temperatures** — every sensor with a meter scaled to the critical point.

## How it is put together

Reading `hwmon` needs no privileges; writing `pwm*` needs root. Rather than
prompt for a password on every slider drag, omacool splits in two:

| Part | Runs as | Does |
|---|---|---|
| `bin/omacool` (bundled in the plugin) | you | reads sysfs, prints JSON for the panel, sends control commands |
| `omacool daemon` (systemd service) | root | applies curves once a second, owns every write to `pwm*` |

They talk over a unix socket at `/run/omacool/omacool.sock`. Control commands are
authorized per-request via Polkit (`io.github.giovesch.omacool.control`).

**Privilege model: Polkit `allow_active: yes`.** Rather than creating a permanent
privileged UNIX group (which Omarchy explicitly avoids), omacool follows the standard
desktop security model using Polkit. The shipped policy grants fan control to whoever
holds the active local desktop session without password prompts. Background processes,
cron jobs, and remote SSH sessions cannot alter fan speeds. If an administrator wishes
to enforce password authentication, setting `allow_active` to `auth_admin_keep` in
`/usr/share/polkit-1/actions/io.github.giovesch.omacool.policy` prompts for root
credentials via Omarchy's Polkit agent.

Two things the daemon does regardless of what you configure:

- **Critical override.** If any sensor reaches `critical_temp` (90 °C by
  default), every controllable fan goes to 100% until it drops. A silent curve
  cannot cook your machine.
- **Clean handback.** On stop, restart, or crash-restart, every fan's original
  `pwm*_enable` value is restored, so the firmware takes over again.

The panel reads sysfs directly, so temperatures and RPMs still show up with the
daemon stopped — the controls just tell you they are read-only.

## Install

Add the plugin to Omarchy:

```sh
omarchy plugin add https://github.com/giovesch/omacool.git --enable
```

### Enabling Fan Control

Writing to `pwm*` requires root privileges for the background service. You can enable it in either of two ways:

1. **Directly from the bar panel (Recommended)**: Open the cooling panel from the bar and click **"Enable Fan Control"**. Omarchy's Polkit prompt will ask for authentication (password or fingerprint), and the service starts immediately.
2. **From the terminal**:
   ```sh
   cd ~/.config/omarchy/plugins/io.github.giovesch.omacool
   sudo ./install.sh
   ```

No logout or reboot is needed — Polkit recognizes the active session immediately.

`install.sh` prints the hardware it found. If no fans are listed, your board's
sensor modules are not loaded — on most desktops `sudo sensors-detect` followed
by a reboot fixes that. Laptops frequently expose no controllable fan at all;
the panel is still useful as a temperature readout there.

### Requirements

- Omarchy Quattro (`omarchy-shell`)
- `python3` — stdlib only, no external packages
- `systemd`
- `polkit` (`pkcheck`, `pkexec`)
- A Nerd Font in the bar (Omarchy ships one)

### Updating

`omarchy plugin update` refreshes the panel but not the installed daemon, since
that lives outside the plugin folder. Re-run `sudo ./install.sh` or click the button
if prompted after an update to keep the two in step.

## Usage

Click the bar glyph to open the panel. Scroll it to change preset in place.

### Keyboard

| Key | Does |
|---|---|
| `j` / `k` | move between presets, fans and sensors |
| `h` / `l` | walk the presets, trim a manual fan by 5%, or select a curve handle |
| `Enter` / `Space` | apply a preset, or expand a fan's controls |
| `a` / `m` / `c` | set the highlighted fan to auto, manual or curve |
| `r` | drop a fan's override and follow the preset again |
| `+` / `-` | raise or lower the selected curve handle |
| `[` / `]` | slide the selected curve handle along the temperature axis |
| `Esc` | close |

### Curves

Curves are `temperature: percent` points, kept sorted and non-decreasing. A
handle dragged below the one to its left clamps rather than dipping — a fan that
slows down as the machine heats up is never what you meant.

By default a curve follows the hottest sensor on the machine, which is usually
what you want: a cool CPU should not keep the case fans idle while the GPU
cooks. Pick a specific sensor from the dropdown under the curve if you'd rather
pin it.

## Command line

The same tool the panel uses:

```sh
omacool status                 # temperatures, RPMs and the active preset
omacool status --json          # the shape the panel parses
omacool list                   # every hwmon chip, sensor and fan
omacool preset                 # list presets; * marks the active one
omacool preset silent
omacool set nct6798/fan2 60    # pin one fan to 60%
omacool mode nct6798/fan2 auto # hand it back to the firmware
omacool curve nct6798/fan1 40:20,60:50,80:100
omacool curve nct6798/fan1 --show
omacool reset nct6798/fan1     # follow the preset again
```

Fan ids are `<chip>/<channel>` and are stable across reboots — they are built
from the driver name, not from the `hwmon0`/`hwmon1` numbering, which is not.

## Configuration

`/etc/omacool/config.json`, rewritten by the daemon whenever you change
something in the panel. Edit it by hand and run `sudo systemctl reload-or-restart
omacool` to pick the changes up.

```json
{
  "preset": "balanced",
  "interval": 1.0,
  "critical_temp": 90,
  "hysteresis": 4,
  "spinup_percent": 45,
  "spinup_ms": 900,
  "socket_mode": "0666",
  "presets": {
    "silent": { "label": "Silent", "mode": "curve",
                "curve": [[35, 0], [50, 20], [65, 35], [78, 60], [88, 100]] }
  },
  "fans": {
    "nct6798/fan1": { "mode": "curve", "sensor": "coretemp/temp1",
                      "curve": [[40, 25], [70, 70], [85, 100]], "min": 20 }
  }
}
```

| Key | Meaning |
|---|---|
| `critical_temp` | force every fan to 100% at or above this reading |
| `hysteresis` | percent points a target must move before the fan is rewritten, so a wobbling sensor does not audibly pulse the fan |
| `spinup_percent` / `spinup_ms` | how hard and how long to kick a stopped fan, which will not restart from a low duty cycle |
| `min` (per fan) | a floor the curve can never go below |
| `socket_mode` | permissions on `/run/omacool/omacool.sock` (defaults to `"0666"`; set to `"0600"` to restrict to root) |

Adding a key to `presets` puts a new chip in the panel automatically.

Applying a preset clears per-fan overrides — a preset is a statement about the
whole machine, and a stale pin silently ignoring it is worse than losing it.

## Safety

Fan control talks straight to your motherboard. Before trusting a silent curve:

- Watch the temperatures under load for a few minutes with the panel open.
- Keep `critical_temp` at or below what your hardware actually tolerates.
- Set a `min` floor on any fan you care about.
- `sudo systemctl stop omacool` hands everything back to the firmware
  immediately.

Nothing here disables your firmware's own thermal protection, which stays the
last line of defence.

## Uninstall

```sh
sudo ./uninstall.sh                 # keeps /etc/omacool
sudo ./uninstall.sh --purge         # removes config and polkit policy too
omarchy plugin remove io.github.giovesch.omacool
```

## Development

```sh
python3 -m unittest discover -s tests -t .
```

The tests build a fake `hwmon` tree and point the tool at it with
`OMACOOL_HWMON`, so they cover discovery, curve maths, hysteresis, spin-up, the
critical override, polkit authorization, and the daemon's socket protocol without
touching real hardware.

## License

MIT — see [LICENSE](LICENSE).
