# ASO VPN

System-wide macOS VPN over SSH ([sshuttle](https://github.com/sshuttle/sshuttle)).

Universal app for **Intel** and **Apple Silicon**. No credentials in the source — add configs in the app.

## Requirements

- macOS 12+
- Xcode Command Line Tools
- Homebrew (installed automatically on first setup if missing)
- Admin password **once** (saved permanently)

## Build

```bash
chmod +x build.sh vpn.sh
./build.sh
open "dist/ASO VPN.app"
```

## Usage

1. Open **ASO VPN**
2. **Add** a config (Name / Host / User / Password / Port) → Save
3. Select it → **Connect** (Mac password once)
4. All TCP + DNS goes through the tunnel

First launch has an empty config list. Configs are kept across app updates:

```text
~/Library/Application Support/ASO VPN/
```

## Layout

| File | Role |
|------|------|
| `VPNApp.m` | GUI |
| `vpn.sh` | Tunnel + privileges |
| `build.sh` | Build `.app` |
| `resources/` | Icon |

## Notes

- Removing the `.app` does not delete saved configs.
- Unsigned builds may be blocked by Gatekeeper on other Macs — build locally on each machine, or notarize before distributing.
