# Device Mesh

SSH-based connectivity between personal devices through aspirant-cell (the home server). Each device authenticates with its own Ed25519 key. The server holds all public keys and controls what each device is allowed to do.

## Architecture

```
Any network (hotspot, home wifi, café, mobile data)
    │
    ├── Phone (Termux) ──SSH──┐
    │                         │
    ├── Laptop ──SSH + tunnel─┤
    │                         │
    ├── reMarkable ───────────┤  (daily rsync, push model)
    │                         │
    │           ┌─────────────┴──────────────────┐
    │           │   aspirant-cell                  │
    │           │   home.the-aspirant.com          │
    │           │   SSH port: 41922                │
    │           │                                  │
    │           │   Reverse tunnels:               │
    │           │     :2200 → laptop:22            │
    │           │                                  │
    │           │   /data/aspirant/                │
    │           │   ~/.ssh/authorized_keys         │
    │           └──────────────────────────────────┘
    │
    └── Direct DNS (no Cloudflare proxy)

Phone → cell:  direct SSH (shell access)
Phone → laptop: ssh laptop (routes through cell via reverse tunnel)
Laptop → cell:  direct SSH + maintains reverse tunnel (:2200)
```

**Connection model:** Devices always connect outward to the cell. The cell never initiates connections to devices. This works behind NAT, hotspots, and any network.

**DNS:** `home.the-aspirant.com` resolves to the cell's public IP (updated every 5 minutes by cron). This record is **not** proxied through Cloudflare, so SSH connections go direct.

## Current Devices

| Device | Key Name | Access Level | Connection |
|--------|----------|-------------|------------|
| Laptop | `laptop` | Full shell + tunnel | On-demand SSH, persistent reverse tunnel on :2200 |
| Phone (Android) | `phone` | Full shell | On-demand SSH via Termux |
| reMarkable Paper Pro | `remarkable` | rsync only | Daily systemd timer |

## How It Works

### Key Storage

Public keys live in this repo under `authorized_keys.d/`, one `.pub` file per device:

```
mesh/
├── authorized_keys.d/
│   ├── laptop.pub
│   ├── phone.pub
│   └── remarkable.pub
├── authorized_keys.template
├── ssh_config
└── README.md
```

The actual `~/.ssh/authorized_keys` on the cell is assembled from these keys plus per-device restrictions. See `authorized_keys.template` for the format.

### Permission Levels

Each device key is restricted in `authorized_keys` using OpenSSH options:

| Level | Options | Use Case |
|-------|---------|----------|
| **Full shell** | *(none)* | Laptop, phone — full SSH access |
| **rsync only** | `command="...validate.sh",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding` | reMarkable — file sync only |
| **Single command** | `command="/path/to/script",no-pty,no-port-forwarding` | Future: backup agents, sensor pushes |
| **Shell + tunnel** | *(none, device also runs autossh)* | Laptop — full access + reverse tunnel for inbound |
| **Tunnel only** | `no-pty,permitopen="localhost:NNNN"` | Future: headless devices that only need to be reachable |

### SSH Config (Client Side)

The `ssh_config` file in this directory is a ready-to-use snippet for `~/.ssh/config` on any client device. It defines the `cell` host alias so you can connect with:

```bash
ssh cell
```

Instead of remembering the hostname, port, user, and key path.

## Adding a New Device

### Step 1: Generate a key on the device

```bash
ssh-keygen -t ed25519 -C "device-name"
```

This creates `~/.ssh/id_ed25519` (private, stays on device) and `~/.ssh/id_ed25519.pub` (public, goes to server).

**Exception:** reMarkable uses Dropbear, not OpenSSH. Use `dropbearkey -t ed25519 -f keyfile` instead. See [aspirant-remarkable/device/INSTALL.md](https://github.com/the-anonymous-aspirant/aspirant-remarkable/blob/main/device/INSTALL.md) for details.

### Step 2: Add the public key to this repo

Copy the `.pub` file into `mesh/authorized_keys.d/`:

```bash
cp ~/.ssh/id_ed25519.pub mesh/authorized_keys.d/device-name.pub
```

Commit and push.

### Step 3: Choose a permission level

Decide what the device should be allowed to do (see Permission Levels above). Update `authorized_keys.template` with the appropriate restrictions for the new key.

### Step 4: Deploy to the cell

On aspirant-cell, append the key to `~/.ssh/authorized_keys` with the chosen restrictions:

```bash
# Full shell access:
cat mesh/authorized_keys.d/device-name.pub >> ~/.ssh/authorized_keys

# Restricted access (example: rsync only):
echo "command=\"/path/to/validate.sh\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding $(cat mesh/authorized_keys.d/device-name.pub)" >> ~/.ssh/authorized_keys
```

### Step 5: Test

```bash
ssh -p 41922 -i ~/.ssh/id_ed25519 aspirant@home.the-aspirant.com
```

Or, if you've installed the SSH config snippet:

```bash
ssh cell
```

### Step 6: Update this README

Add the device to the "Current Devices" table above.

## Removing a Device

1. Delete the `.pub` file from `mesh/authorized_keys.d/`
2. Remove the corresponding line from `~/.ssh/authorized_keys` on the cell
3. Remove the device from the "Current Devices" table
4. Commit and push

The device's private key becomes useless immediately — it can no longer authenticate.

## Extending: Reverse Tunnels

For devices that need to be **reachable through the cell** (e.g., a Raspberry Pi behind NAT), use a reverse SSH tunnel. The device dials out to the cell and exposes a local port:

```bash
# On the device:
autossh -N -R NNNN:localhost:22 cell
```

This makes the device reachable from the cell (or through the cell) at `localhost:NNNN`.

### Reverse Tunnel Port Allocation

Reserve ports in the 2200-2299 range for reverse tunnels. Track allocations here:

| Port | Device | Target |
|------|--------|--------|
| 2200 | Laptop | laptop:22 |

When adding a reverse tunnel device:

1. Pick the next available port in the 2200-2299 range
2. Add the port to the table above
3. On the device, set up `autossh` as a systemd service for persistence:

```ini
[Unit]
Description=Reverse SSH tunnel to aspirant-cell
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/autossh -M 0 -N -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -R NNNN:localhost:22 cell
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

4. Add an SSH config entry for the device (using `ProxyJump`):

```
Host device-name
  HostName localhost
  Port NNNN
  User user
  ProxyJump cell
```

Then `ssh device-name` routes through the cell automatically.

## Extending: Phone Hotspot Mesh

When using a phone as a Wi-Fi hotspot, connected devices (laptop, tablet) share a private LAN:

```
Phone (hotspot gateway)
  ├── Laptop   192.168.43.x
  └── Tablet   192.168.43.y
```

Devices can SSH to each other directly on the local subnet. They can also reach the cell via the phone's mobile data. The SSH config and keys work identically — the mesh is network-agnostic.

Typical hotspot IP ranges:
- Android: `192.168.43.x`
- iOS: `172.20.10.x`

## Phone Setup (Android / Termux)

Termux provides a full Linux environment on Android with OpenSSH built in. No root required.

### Install Termux

Install [Termux from F-Droid](https://f-droid.org/en/packages/com.termux/) (not the Play Store version — it's outdated and broken).

### Generate SSH key

```bash
pkg install openssh
ssh-keygen -t ed25519 -C "phone"
```

This creates `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub` inside Termux's home directory.

### Install SSH config

Create `~/.ssh/config` in Termux:

```
Host cell
  HostName home.the-aspirant.com
  Port 41922
  User aspirant
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 30
  ServerAliveCountMax 3

Host laptop
  HostName localhost
  Port 2200
  User <laptop-user>
  ProxyJump cell
```

### Deploy key to cell

Copy the public key content:

```bash
cat ~/.ssh/id_ed25519.pub
```

Then add it to `~/.ssh/authorized_keys` on the cell (no restrictions — full shell):

```bash
# On the cell:
echo "ssh-ed25519 AAAA... phone" >> ~/.ssh/authorized_keys
```

### Test

```bash
# Phone → cell:
ssh cell

# Phone → laptop (through cell, requires laptop reverse tunnel running):
ssh laptop
```

### Persistence

Termux sessions survive screen lock but not app termination. For a persistent connection, use `tmux`:

```bash
pkg install tmux
tmux new -s ssh
ssh cell
# Ctrl+B, D to detach — session survives
# tmux attach -t ssh  to reconnect
```

For the SSH config and key to survive Termux app data wipes, back up `~/.ssh/` to the cell:

```bash
tar czf - ~/.ssh | ssh cell "cat > /data/aspirant/backups/phone-ssh.tar.gz"
```

## Laptop Reverse Tunnel Setup

The laptop maintains a reverse SSH tunnel to the cell so other devices (like the phone) can reach it. The tunnel maps cell port 2200 to the laptop's SSH port (22).

### Prerequisites

- `autossh` installed on the laptop (`brew install autossh` on macOS)
- SSH key already deployed to the cell (see Adding a New Device above)
- SSH server running on the laptop (macOS: System Settings > General > Sharing > Remote Login)

### Manual start

```bash
autossh -M 0 -N -R 2200:localhost:22 cell
```

This opens a persistent tunnel: `cell:2200 → laptop:22`. Other mesh devices can now reach the laptop through the cell.

### Persistent (macOS launchd)

Create `~/Library/LaunchAgents/com.aspirant.tunnel.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aspirant.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/autossh</string>
        <string>-M</string>
        <string>0</string>
        <string>-N</string>
        <string>-o</string>
        <string>ServerAliveInterval 30</string>
        <string>-o</string>
        <string>ServerAliveCountMax 3</string>
        <string>-R</string>
        <string>2200:localhost:22</string>
        <string>cell</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/tmp/aspirant-tunnel.err</string>
    <key>StandardOutPath</key>
    <string>/tmp/aspirant-tunnel.log</string>
</dict>
</plist>
```

Load it:

```bash
launchctl load ~/Library/LaunchAgents/com.aspirant.tunnel.plist
```

The tunnel will start on login and restart automatically if it drops.

### Verify

From the cell:

```bash
ssh -p 2200 <laptop-user>@localhost
```

From the phone:

```bash
ssh laptop
```

## Security Model

### Principles

- **Private keys never leave the device.** They are never committed, copied, or transmitted.
- **Public keys are safe to commit.** They are useless without the corresponding private key.
- **Each device gets its own key.** Compromising one device doesn't compromise others — revoke the one key.
- **Minimum privilege.** Devices get only the access they need (rsync, shell, tunnel).
- **No passwords.** `PasswordAuthentication no` on the cell. Key-only.
- **Cell is the single trust anchor.** All authentication decisions happen in `authorized_keys` on the cell.

### Cell SSH Hardening

The cell's `sshd_config` is hardened with:

| Setting | Value | Why |
|---------|-------|-----|
| `Port` | `41922` | Non-standard port reduces automated scanning noise |
| `PasswordAuthentication` | `no` | Key-only authentication |
| `KbdInteractiveAuthentication` | `no` | No challenge-response |
| `PermitRootLogin` | `no` | Root cannot SSH in, even with a key |
| `X11Forwarding` | `no` | Unnecessary on a headless server |
| `MaxAuthTries` | `3` | Limits brute-force attempts per connection |
| `AllowUsers` | `aspirant` | Only the `aspirant` user can SSH in |

### Key Inventory

The cell's `authorized_keys` should contain exactly these keys:

| Key Comment | Purpose | Restrictions |
|-------------|---------|-------------|
| `the-anonymous-aspirant@github/...` | GitHub deploy key (legacy, for git operations) | None |
| `remarkable-sync` | reMarkable tablet sync | `command=`, `no-pty`, `no-port-forwarding`, `no-agent-forwarding`, `no-X11-forwarding` |
| `pixelphone` | Android phone (Termux) | None (full shell) |
| `laptop` | Laptop | None (full shell) |

The laptop's `authorized_keys` should contain:

| Key Comment | Purpose | Restrictions |
|-------------|---------|-------------|
| `pixelphone` | Phone → laptop via reverse tunnel | None (full shell) |

### Validation Script Security

The reMarkable sync validation script (`remarkable-sync-validate.sh`) restricts the device key to rsync operations only. It includes:

- **Command whitelist:** Only `rsync --server` and specific `curl` commands are allowed
- **Path restriction:** rsync targets must be `xochitl/` or `to-device/` under `/data/aspirant/remarkable/`
- **Injection filter:** Commands containing `;`, `|`, `&`, backticks, `$(`, `>`, or `<` are rejected before matching
- **Access logging:** All allowed and denied commands are logged to `sync-access.log`

### What This Repo Contains (Safe)

- Public keys (`.pub` files)
- SSH config templates (hostnames, ports, usernames)
- Documentation

### What This Repo Must Never Contain

- Private keys (`id_ed25519`, `*.pem`, Dropbear private keys)
- Passwords or tokens
- The assembled `authorized_keys` file with server-side paths

### If a Device Is Lost or Compromised

1. Remove the device's key from `authorized_keys` on the cell (and laptop if applicable)
2. Delete the `.pub` file from this repo
3. Update the "Current Devices" table
4. If the compromised device had full shell access, audit for unauthorized changes on the cell

## Troubleshooting

### "Connection refused" on port 41922

The cell's SSH daemon isn't running or the port isn't forwarded. Check:
```bash
# On the cell:
sudo systemctl status ssh
sudo ss -tlnp | grep 41922
```

### "Permission denied (publickey)"

The key isn't in `authorized_keys` on the cell, or the key type doesn't match. Check:
```bash
# Verbose SSH to see what keys are offered:
ssh -vvv -p 41922 aspirant@home.the-aspirant.com
```

### DNS not resolving

The dynamic DNS cron may have failed. Check:
```bash
# On the cell:
crontab -l | grep dns
cat ~/update-dns.sh
```

### reMarkable sync fails

See [aspirant-remarkable/device/INSTALL.md](https://github.com/the-anonymous-aspirant/aspirant-remarkable/blob/main/device/INSTALL.md) for device-specific troubleshooting. Common issues:
- Device password changed after reboot (doesn't affect key-based sync)
- Dropbear key format mismatch
- Network unreachable (check wifi on device)
