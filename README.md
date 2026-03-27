# PatchWave – Automated Linux Patch Management

## Overview

PatchWave is an Ansible role for automated Linux patch management. It orchestrates the full patch lifecycle across multiple hosts:

- Detect the Linux distribution and run the appropriate package manager.
- Optionally create a Proxmox VM snapshot before patching.
- Stop defined services and run custom pre-reboot scripts.
- Reboot the system (always or only when required).
- Restart services in reverse order and run custom post-reboot scripts.
- Send structured notifications via [ntfy.sh](https://github.com/binwiederhier/ntfy) and/or webhooks (JSON POST) at each stage (optional).
- Schedule everything via systemd timers with configurable patch windows.

PatchWave has no web interface, no database, and no API server. It relies entirely on Bash, systemd, and Ansible — tools already present on your Linux systems.

## Why PatchWave / Where is the GUI?

There isn't one — and that's intentional.

Most patch management solutions require a dedicated server, a database, an agent on every host, and a web interface to maintain. PatchWave takes a different approach: it deploys a few shell scripts and a systemd timer directly to each host. Nothing else runs permanently. No agent, no daemon, no port to expose.

If you already manage your infrastructure with Ansible and want automated patching without adding a new system to operate, PatchWave is designed for that. The full operational surface is: some Bash, a systemd timer, and a log file. That's it.

**PatchWave is for you if:**
- You manage Linux servers with Ansible and want patch automation that fits into that workflow
- You prefer auditable shell scripts over opaque agents
- You don't want to run a patch management server just to keep your servers up to date
- You're comfortable reading a shell script to understand what a tool does

**PatchWave is probably not for you if:**
- You need a dashboard, approval workflows, or compliance reporting
- You manage Windows hosts
- You need patch rollback (the Proxmox snapshot integration covers the basics, but it is not a substitute for a proper rollback workflow)

---

## Disclaimer

Automated patching carries the risk of unintended side effects. **Ensure that backups, snapshots, or other recovery mechanisms are in place before running the patch process.** The maintainers of this project are not responsible for any data loss, service disruption, or other issues resulting from its use.

---

## Supported Distributions

- **Debian / Ubuntu** (APT)
- **RHEL / CentOS / Rocky / AlmaLinux** (DNF)
- **openSUSE / SLES** (Zypper)
- **Arch Linux** (Pacman)

---

## How It Works

The following diagram shows the full patch lifecycle for a single host. Understanding this flow helps when configuring services, custom scripts, or notifications.

```
patchwave-patch.sh
├── Detect Linux distribution
├── Write patch_start event to events.jsonl
├── Create Proxmox snapshot (optional)
├── Run package updates (apt/dnf/zypper/pacman)
├── Check if reboot is required
│
├── [Reboot required]
│   └── patchwave-pre-reboot.sh
│       ├── Stop systemd services (in order)
│       ├── Run custom pre-reboot scripts
│       ├── Send reboot notification (ntfy.sh, optional)
│       └── Reboot
│           └── patchwave-post-reboot.sh (on boot)
│               ├── Start systemd services (reverse order)
│               ├── Run custom post-reboot scripts
│               ├── Delete Proxmox snapshot (optional)
│               ├── Write patch_success event to events.jsonl
│               ├── Send success notification (ntfy.sh, optional)
│               └── Send webhook on_success (optional)
│
├── [No reboot required]
│   ├── Write patch_success event to events.jsonl
│   ├── Send success notification (ntfy.sh, optional)
│   └── Send webhook on_success (optional)
│
└── [Any error]
    ├── Write patch_failure event to events.jsonl
    ├── Send error notification (ntfy.sh, optional)
    └── Send webhook on_fail (optional)
```

---

## Quickstart

This section covers the minimum steps to get PatchWave running. For detailed configuration of all features, see [Configuration](#configuration).

### Prerequisites

- **Ansible 2.12+** on a control node
- **SSH access** to all managed hosts with sudo/root privileges
- **Optional:** [ntfy.sh](https://ntfy.sh) for push notifications

### Runtime Dependencies

PatchWave installs the following third-party packages automatically on each managed host during deployment:

| Package | Purpose | Installed by |
|---|---|---|
| `jq` | JSON generation for event log and webhook payloads | All hosts |
| `needrestart` | Detect processes using outdated libraries after patching | All hosts |
| `curl` | Notifications (ntfy.sh), webhooks, Proxmox API calls | All hosts |

> **Note for RHEL-based systems:** `needrestart` is available in the [EPEL](https://docs.fedoraproject.org/en-US/epel/) repository. Ensure EPEL is enabled on your RHEL/CentOS/Rocky/AlmaLinux hosts before deploying PatchWave.

### 1. Clone the Repository

```bash
git clone https://github.com/DSc5/PatchWave.git
cd PatchWave
```

### 2. Set Up the Inventory

```bash
cp patchwave.ini.example patchwave.ini
```

The PatchWave inventory assigns hosts to patch window groups. Connection details (`ansible_host`, `ansible_user`, etc.) should remain in your global inventory:

```ini
[patchwave_window_sunday_05]
web01.example.com
web02.example.com

[patchwave_window_sunday_12]
db01.example.com
db02.example.com
```

### 3. Define Patch Windows

Each patch window group needs a corresponding file in `group_vars/`:

```bash
cp group_vars/patchwave_window.yml.template group_vars/patchwave_window_sunday_12.yml
```

The filename must match the group name. The value follows [systemd OnCalendar syntax](https://www.freedesktop.org/software/systemd/man/systemd.time.html):

```yaml
patchwave_patch_window: "Sun 12:00"          # Every Sunday at noon
patchwave_patch_window: "Wed 03:00"          # Every Wednesday at 3 AM
patchwave_patch_window: "Sat *-*-1..7 04:00" # First Saturday of each month at 4 AM
```

Per-host overrides are possible via `host_vars/<hostname>.yml`.

### 4. Deploy

```bash
ansible-playbook -i /etc/ansible/hosts -i patchwave.ini deploy_patchwave.yml
```

That's it — PatchWave will run on schedule. Read on to customize the behavior.

---

## Configuration

All variables are defined with defaults in [`roles/patchwave/defaults/main.yml`](#variable-reference). Override them in `group_vars/all/vars.yml` (global) or `host_vars/<hostname>.yml` (per host). You only need to set values that differ from the defaults.

```bash
cp group_vars/all/vars.yml.template group_vars/all/vars.yml
cp host_vars/host_vars.yml.template host_vars/<hostname>.yml
```

To protect sensitive values (e.g. Proxmox API tokens), use [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html). A template is provided in `group_vars/all/vault.yml.template`.

> **How configuration reaches the host:** During deployment, Ansible renders all variable values into `/etc/patchwave/config.sh` on each managed host. This file is the single runtime source of truth for all PatchWave scripts. It is owned by root and not readable by other users — you do not need to edit it directly.

### Reboot Policy

```yaml
patchwave_reboot_policy: "always"         # Default: reboot after every patch run
patchwave_reboot_policy: "when_required"  # Only reboot when the system indicates it
```

When set to `when_required`, PatchWave uses `needrestart` (installed automatically on all managed hosts) to determine whether a reboot is necessary. A reboot is triggered when `needrestart` reports a pending kernel version upgrade (`NEEDRESTART-KSTA: 3`).

### Service Management

Define which systemd services to stop before patching and restart afterward:

```yaml
# host_vars/<hostname>.yml
patchwave_services:
  - mysql
  - postgresql
```

Services are stopped top-to-bottom and restarted bottom-to-top. List them in dependency order (dependencies last).

### Custom Scripts

PatchWave can execute custom scripts at two points in the patch lifecycle:

| Hook | Variable | When executed |
|---|---|---|
| Pre-reboot scripts | `patchwave_pre_reboot_scripts` | After `patchwave_services` are stopped, before reboot |
| Post-reboot scripts | `patchwave_post_reboot_scripts` | After reboot, after `patchwave_services` are restarted |

Scripts are defined as absolute paths on the managed host and configured per host:

```yaml
# host_vars/<hostname>.yml

patchwave_pre_reboot_scripts:
  - /usr/local/bin/flush-app-cache.sh
  - /usr/local/bin/notify-cmdb.sh

patchwave_post_reboot_scripts:
  - /usr/local/bin/verify-services.sh
```

Scripts are executed in list order. The scripts themselves must exist on the managed host — PatchWave does not deploy them, it only calls them.

#### Timeout and Error Handling

Each script runs with a timeout of `patchwave_script_timeout` (default: 300 seconds). PatchWave checks the exit code after each script:

- Exit code `0` → success, continue
- Exit code `124` → script timed out → abort with error notification
- Any other non-zero exit code → script failed → abort with error notification

Scripts must be executable (`chmod +x`). If a script is not found or not executable, PatchWave aborts with an error.

**Note on cumulative runtime:** The timeout applies per script, not to the total run. If you configure multiple scripts, the maximum total execution time is `number of scripts × patchwave_script_timeout`. Keep this in mind when setting the timeout value and planning your systemd patch window.

**Only the final exit code is evaluated.** Commands that fail silently inside a script (e.g. a failed `grep` or a backgrounded process) will not be caught automatically.

#### Best Practices

Always exit explicitly and handle errors deliberately:

```bash
#!/bin/bash
set -euo pipefail   # abort on error, unset variable, or failed pipe

# Your logic here
some_command || { echo "some_command failed"; exit 1; }

exit 0
```

Guidelines:

- **Use `set -euo pipefail`** so unhandled errors cause a non-zero exit code
- **Avoid fire-and-forget backgrounding** (`some_cmd &`) — the script will exit 0 even if the background process fails
- **Keep scripts well within the timeout** — the timer starts fresh for each script, but a slow script blocks the reboot or service restart
- **Test scripts independently** before deploying, since failures abort the entire patch run

#### Example: Notify an External System Before Reboot

```bash
#!/bin/bash
# /usr/local/bin/notify-cmdb.sh
set -euo pipefail

curl -sf -X POST "https://cmdb.example.com/api/maintenance" \
  -H "Content-Type: application/json" \
  -d "{\"host\": \"$(hostname)\", \"status\": \"patching\"}" \
  || { echo "CMDB notification failed"; exit 1; }

exit 0
```

### Notifications (ntfy.sh)

PatchWave can send push notifications via [ntfy.sh](https://ntfy.sh). Notifications are disabled by default — set a topic to enable them:

```yaml
patchwave_ntfy_topic: "https://ntfy.sh/your-topic"
```

| Event | Priority | When Sent |
|---|---|---|
| Patch error | High | Always |
| Rebooting | Default | Always |
| Patch success | Default | Only when `patchwave_notify_level: "always"` |

Notifications include host, distro, package count, duration, reboot status, and service state.

If your ntfy instance uses a self-signed certificate, set `patchwave_tls_insecure: true` to skip TLS verification. This is not recommended in production — prefer a properly signed certificate or a trusted CA.

### Webhooks

PatchWave can send a JSON `POST` request to a configurable URL on success or failure:

```yaml
patchwave_webhook_on_success: "https://your-endpoint/hook"
patchwave_webhook_on_fail: "https://your-endpoint/hook"
```

Both are independent — set either or both. The payload is always `Content-Type: application/json`.

If your webhook endpoint uses a self-signed certificate, set `patchwave_tls_insecure: true` to skip TLS verification. This setting applies to all curl-based calls (ntfy, webhooks, Proxmox API). This is not recommended in production — prefer a properly signed certificate or a trusted CA.

#### Success Payload

```json
{
  "event": "success",
  "host": "host01.example.com",
  "timestamp": "2024-06-01T03:05:42Z",
  "distro": "ubuntu",
  "packages_changed": 12,
  "packages_updated": ["curl", "libssl3", "openssh-client"],
  "duration_seconds": 87,
  "reboot": true
}
```

The `reboot` field is `false` when no reboot was required.

#### Failure Payload

```json
{
  "event": "failure",
  "host": "host02.example.com",
  "timestamp": "2024-06-01T03:05:42Z",
  "message": "APT update failed on host02.example.com!"
}
```

Failures include any `error_exit` condition: package manager errors, service stop/start failures, custom script failures, and timeouts.

### Proxmox VM Snapshots

PatchWave can create a Proxmox VM snapshot before patching and automatically delete it after success.

In `group_vars/all/vars.yml`:

```yaml
proxmox_snapshot_before_patch: true
proxmox_snapshot_delete_after_successful_patch: true
proxmox_host: "proxmox.example.com"
proxmox_node: "pve"
proxmox_token: "PVEAPIToken=<full-tokenid>=<token>"
```

In `host_vars/<hostname>.yml`:

```yaml
proxmox_vmid: 100
```

If the snapshot creation fails, patching is aborted with an error notification. Consider protecting the API token with [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html).

The token is written to `/etc/patchwave/config.sh` on each managed host (mode `0640`, owned by root). Only root-level processes can read it. Using ansible-vault protects the token in your repository and during transfer — on the host, file permissions are the security boundary.

#### Creating a Dedicated Proxmox User

```bash
pveum user add patchwave@pve
pveum role add SnapshotOnly -privs "VM.Snapshot"
pveum aclmod /vms --user patchwave@pve --roles SnapshotOnly
pveum user token add patchwave@pve snapshot_token --privsep=0
```

#### Testing API Access

```bash
curl -k -X POST "https://<proxmox-host>:8006/api2/json/nodes/<node>/qemu/<vmid>/snapshot" \
     -H "Authorization: PVEAPIToken=<full-tokenid>=<token>" \
     -H "Content-Type: application/json" \
     -d '{"snapname": "test_snapshot"}'
```

---

## Usage

```bash
# Trigger patch manually on the target host
/usr/local/bin/patchwave-patch.sh

# Or via systemd
systemctl start patchwave.service

# View scheduled timers
systemctl list-timers --all | grep patchwave

# Disable/enable automatic patching
systemctl disable patchwave.timer
systemctl enable --now patchwave.timer
```

If no `patchwave_patch_window` is defined for a host, the timer is automatically removed on the next playbook run.

---

## Logging & Observability

### Log Files

PatchWave writes human-readable log files per run into `patchwave_log_dir` (default: `/var/log/patchwave/`):

- `summary_<timestamp>.log` – all steps, service stops/starts, and errors
- `patch_updates_<timestamp>.log` – raw package manager output

Logrotate is configured automatically. Retention is controlled via `patchwave_log_retention_days` (default: 90).

### Structured Events (events.jsonl)

In addition to the human-readable logs, PatchWave appends structured events to a [JSON Lines](https://jsonlines.org/) file — one JSON object per line, plain text, no schema — intended for machine consumption and integration with external tooling.

Default path: `/var/log/patchwave/events.jsonl` (managed by logrotate, configurable via `patchwave_event_log`).

| Event | When |
|---|---|
| `patch_start` | Distro detected, package manager about to run |
| `patch_success` | Run completed without errors |
| `patch_failure` | Any error condition (`error_exit`) |

```json
{"timestamp":"2024-06-01T03:00:01Z","host":"host01.example.com","event":"patch_start","distro":"ubuntu"}
{"timestamp":"2024-06-01T03:01:28Z","host":"host01.example.com","event":"patch_success","distro":"ubuntu","packages_changed":3,"packages_updated":["curl","libssl3","openssh-client"],"duration_seconds":87,"reboot":true}
{"timestamp":"2024-06-01T03:00:05Z","host":"host02.example.com","event":"patch_failure","message":"APT update failed on host02.example.com!"}
```

`packages_updated` contains the names of packages whose version changed (new installs and upgrades). Derived from a before/after diff of the installed package list — no external tools required.

### Ad-hoc Queries with jq

```bash
# All failures
jq 'select(.event == "patch_failure")' /var/log/patchwave/events.jsonl

# Which packages were updated on a specific host
jq 'select(.event == "patch_success" and .host == "host01.example.com") | .packages_updated[]' \
  /var/log/patchwave/events.jsonl

# All hosts that received a specific package update
jq -r 'select(.event == "patch_success") | select(.packages_updated | index("curl")) | .host' \
  /var/log/patchwave/events.jsonl

# Successful runs in the last 7 days
jq --arg since "$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')" \
  'select(.event == "patch_success" and .timestamp >= $since)' \
  /var/log/patchwave/events.jsonl
```

### Integration with Log Shippers

The file format is natively supported by Promtail (Loki), Filebeat (Elasticsearch/OpenSearch), Vector, Fluentd, and Grafana Alloy — no PatchWave-specific plugin needed. Point any of these at `events.jsonl` and parse as NDJSON/JSON Lines.

---

## Variable Reference

All variables are defined in `roles/patchwave/defaults/main.yml`. Override priority (highest first):

1. `host_vars/<hostname>.yml`
2. `group_vars/<group>.yml`
3. `group_vars/all/vars.yml`
4. `roles/patchwave/defaults/main.yml`

| Variable | Default | Description |
|---|---|---|
| `patchwave_reboot_policy` | `always` | `always` or `when_required` |
| `patchwave_apt_upgrade_mode` | `upgrade` | `upgrade` or `full-upgrade` (Debian/Ubuntu only) |
| `patchwave_services` | `[]` | Services to stop/start around patching |
| `patchwave_pre_reboot_scripts` | `[]` | Absolute paths to scripts run before reboot (in order) |
| `patchwave_post_reboot_scripts` | `[]` | Absolute paths to scripts run after reboot (in order) |
| `patchwave_script_timeout` | `300` | Timeout for custom scripts (seconds) |
| `patchwave_patch_window` | *(undefined)* | systemd OnCalendar expression |
| `patchwave_ntfy_topic` | *(empty)* | ntfy.sh URL; empty = notifications disabled |
| `patchwave_notify_level` | `always` | `always` or `errors_only` |
| `patchwave_webhook_on_success` | *(empty)* | URL to POST JSON payload on success |
| `patchwave_webhook_on_fail` | *(empty)* | URL to POST JSON payload on failure |
| `patchwave_tls_insecure` | `false` | Skip TLS certificate verification for all curl calls (ntfy, webhooks, Proxmox API). Not recommended in production. |
| `patchwave_event_log` | `/var/log/patchwave/events.jsonl` | Path to JSON Lines event log; empty = disabled |
| `patchwave_log_retention_days` | `90` | Days to keep log files (via logrotate) |
| `patchwave_config_dir` | `/etc/patchwave` | Configuration and shared files |
| `patchwave_state_dir` | `/var/lib/patchwave` | Runtime state (markers, timestamps) |
| `patchwave_log_dir` | `/var/log/patchwave` | Log files |
| `patchwave_script_dir` | `/usr/local/bin` | Installed scripts |
| `proxmox_snapshot_before_patch` | `false` | Create snapshot before patching |
| `proxmox_snapshot_delete_after_successful_patch` | `true` | Delete snapshot after success |
| `proxmox_host` | — | Proxmox API hostname |
| `proxmox_node` | — | Proxmox node name |
| `proxmox_token` | — | Proxmox API token (consider ansible-vault) |
| `proxmox_vmid` | — | VM ID (typically set per host) |

---

## License

MIT License

## Contributing

Pull requests and issues are welcome.