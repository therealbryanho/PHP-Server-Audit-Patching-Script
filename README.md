# PHP Server Audit & Patching Script

A Bash utility for auditing, planning, and applying PHP package updates on Ubuntu and Debian servers that use `systemd`.

The script helps administrators inspect installed PHP packages, identify active PHP-FPM services and configured pools, review available APT updates, simulate the proposed changes, and apply approved updates with service verification.

## Important: Package Scope Warning

> **This script upgrades ALL matching installed APT-managed PHP packages on the server, not only the PHP version currently used by your websites.**

The package selection includes:

- `php-common`
- Version-specific PHP packages matching `phpX.Y-*`
- Version-specific Apache PHP modules matching `libapache2-mod-phpX.Y`

For example, if PHP 8.1, 8.2, and 8.3 packages are installed, the script may propose updates for all three versions even if the websites currently use only PHP 8.2.

This means:

- Multiple installed PHP versions may be updated at the same time.
- Unused PHP versions are not automatically excluded.
- PHP CLI and PHP-FPM packages may both be upgraded.
- Apache PHP modules may also be upgraded.
- Applications using different PHP versions can be affected.

The script does not determine which PHP version is safe to update based on individual website usage. It selects packages by their installed APT package names.

Treat `apply` as a **server-wide PHP package maintenance operation**, not as a targeted update of one website or one PHP-FPM instance.

Always review the proposed changes before applying them:

```bash
sudo ./php-patch.sh plan
```

Pay particular attention to the APT simulation output. Do not run `apply` until every proposed package change has been reviewed and accepted. If only one PHP version should be updated, the script must be modified to use version-specific package selection.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Supported Platforms](#supported-platforms)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Execution Modes](#execution-modes)
- [How It Works](#how-it-works)
- [Safety Mechanisms](#safety-mechanisms)
- [Example Output](#example-output)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Production Recommendations](#production-recommendations)

## Overview

Managing several PHP versions on a production server can be difficult when different websites use different PHP-FPM pools, Apache modules, or handlers. The script provides visibility into the PHP environment before package changes are made.

It supports three modes:

| Mode | Description | Changes packages? |
|---|---|---:|
| `audit` | Inspects installed PHP packages, runtimes, FPM services, pools, and web-server configuration. | No |
| `plan` | Runs the audit, refreshes APT indexes, lists available PHP updates, and simulates the upgrade. | No |
| `apply` | Runs the audit, validates configuration, asks for confirmation, installs updates, restarts relevant services, and verifies them. | Yes |

If no mode is supplied, the script defaults to `audit`.

## Features

- Detects installed APT-managed PHP packages and full package revisions.
- Reports the default CLI PHP version separately from website runtimes.
- Identifies active `phpX.Y-fpm.service` units and their process executables.
- Reports configured PHP-FPM pool listeners.
- Inspects common Apache and Nginx PHP integration configuration.
- Refreshes package indexes in `plan` and `apply` modes.
- Limits package operations to matching installed PHP packages.
- Shows available updates and runs an APT simulation before applying changes.
- Validates PHP-FPM and web-server configuration before package installation.
- Requests explicit administrator confirmation before `apply` changes the system.
- Restarts active PHP-FPM services after an upgrade.
- Verifies service status after the operation.
- Uses strict Bash error handling and predictable locale settings.

## Supported Platforms

The script is intended for:

- Ubuntu systems using `systemd` and APT.
- Debian systems using `systemd` and APT.

It is not intended for RPM-based distributions, non-systemd environments, source-built PHP installations, or containers that do not run a normal host `systemd` instance.

## Requirements

The script must be run as root, normally through `sudo`, and requires:

- Bash
- `systemd` and `systemctl`
- APT and `dpkg-query`
- Standard tools such as `awk`, `grep`, `sed`, `readlink`, and `find`
- PHP and/or PHP-FPM packages installed for meaningful audit results

The script reads system state from locations including `/etc/os-release`, `/etc/php`, `/etc/apache2`, `/etc/nginx`, and `/proc`.

## Installation

Copy the script to the server, make it executable, and inspect it before use:

```bash
chmod 750 php-patch.sh
less php-patch.sh
```

Optionally place it in an administrator-controlled directory such as `/usr/local/sbin`:

```bash
sudo install -o root -g root -m 0750 php-patch.sh /usr/local/sbin/php-patch.sh
```

Before using it on production, test it on a representative non-production host or snapshot the server according to your normal change-management process.

## Usage

Run the script with one of the supported modes:

```bash
sudo ./php-patch.sh audit
sudo ./php-patch.sh plan
sudo ./php-patch.sh apply
```

The equivalent default invocation is:

```bash
sudo ./php-patch.sh
```

which runs `audit`.

An invalid mode causes the script to exit with a usage message:

```text
Usage: ./php-patch.sh [audit|plan|apply]
```

## Execution Modes

### `audit`

The read-only audit reports:

1. Installed APT-managed PHP packages and their complete revisions.
2. The default CLI PHP version, if the `php` command exists.
3. Active PHP-FPM service units, main PIDs, and process executables.
4. PHP-FPM binary versions where available.
5. PHP-FPM pool listener settings.
6. Relevant web-server PHP configuration.

This mode does not refresh package indexes, install packages, restart services, or modify configuration.

### `plan`

The planning mode performs the audit, then:

1. Refreshes APT package indexes.
2. Determines which matching installed PHP packages have updates available.
3. Prints the candidate package changes.
4. Runs an APT simulation without installing packages.

Use this mode to review package scope and expected dependency changes before scheduling maintenance.

### `apply`

The apply mode performs the audit and planning steps, then:

1. Validates relevant PHP-FPM and web-server configuration.
2. Displays the proposed package operation.
3. Requests explicit administrator confirmation.
4. Installs the matching PHP package updates.
5. Restarts active PHP-FPM services when needed.
6. Verifies the resulting service status and configuration.

If validation fails or confirmation is not provided, the script stops without applying the package changes.

## How It Works

### Package discovery

The package query examines installed APT records and selects packages matching the PHP package families used by the script. This includes `php-common`, versioned `php` packages, and versioned `libapache2-mod-php` packages.

The package list is based on installed package names, not on the PHP version used by a particular website. See the [package scope warning](#important-package-scope-warning) before using `apply`.

### Runtime discovery

The audit distinguishes the default CLI runtime from website runtimes. The output of `php -r` describes the CLI command selected by the system, which may differ from PHP-FPM or an Apache module serving a website.

Active services are discovered from `systemd` using names such as:

```text
php8.2-fpm.service
php8.3-fpm.service
```

The script also checks each service's main process and executable path where possible.

### Configuration discovery

PHP-FPM pool files under `/etc/php/*/fpm/pool.d/` are inspected for `listen` directives. These listeners help show whether a pool uses a Unix socket or a TCP endpoint.

Web-server configuration is inspected to help identify Apache modules, Apache PHP handlers, Nginx FastCGI configuration, and other visible PHP integration points. Configuration discovery is informational; it does not prove which virtual host serves every request.

### Planning and simulation

`plan` and `apply` refresh the APT indexes and construct an operation from the matching installed PHP packages. The APT simulation is shown before any real installation so that dependency changes and the complete package scope can be reviewed.

### Applying and verifying updates

After confirmation, `apply` installs the selected package updates, restarts relevant active PHP-FPM services, and checks service status. Configuration validation and post-update checks are intended to catch common failures, but they cannot replace application-level testing.

## Safety Mechanisms

- `set -Eeuo pipefail` enables strict error handling.
- The locale is fixed to `C` for predictable command output.
- Unsupported modes fail immediately.
- The script requires root privileges.
- Only Ubuntu and Debian are accepted.
- A running `systemd` environment is required.
- `audit` is read-only.
- `plan` uses simulation and does not install packages.
- `apply` validates configuration before changing packages.
- `apply` requires explicit confirmation.
- Active services are checked after the update.

These controls reduce operational risk but do not make an upgrade risk-free. Always review the output and maintain a tested rollback or recovery plan.

## Example Output

The exact output depends on the host, installed versions, and enabled services. A typical audit is structured like this:

```text
== Installed APT PHP packages and full package revisions ==
php-common    2:93ubuntu2
php8.2-cli    8.2.x-...
php8.2-fpm    8.2.x-...
php8.3-fpm    8.3.x-...

== Default CLI PHP (not the website runtime) ==
8.2.x (cli)

== Active PHP-FPM units and process executables ==
php8.2-fpm.service  PID=...  running=/usr/sbin/php-fpm8.2

== Configured PHP-FPM pool listeners ==
/etc/php/8.2/fpm/pool.d/www.conf:listen = /run/php/php8.2-fpm.sock
```

In `plan` mode, the output also includes APT candidates and a simulated transaction. Review every PHP package listed, including versions not currently used by websites.

## Troubleshooting

### `Run with sudo.`

Run the script as root:

```bash
sudo ./php-patch.sh audit
```

### `Only Ubuntu and Debian are supported.`

The script checks `/etc/os-release`. Confirm that the host is Debian or Ubuntu, or adapt the package-management logic for the target distribution.

### `This script requires systemd.`

Run it on a normal systemd host. Containers, chroots, WSL environments, and minimal recovery environments may not provide the required systemd service manager.

### No active PHP-FPM services are shown

The host may use Apache's module integration, a manually launched FPM process, a differently named service, or no active FPM service. Check the service manager and web-server configuration independently.

### The CLI version differs from the website version

This is expected. The default `php` command is the CLI runtime and is not necessarily the PHP-FPM pool or Apache handler used by a website. Use the FPM service, pool listener, and web-server output to investigate the serving runtime.

### The plan includes more packages than expected

Review the [package scope warning](#important-package-scope-warning). The script intentionally considers all matching installed APT-managed PHP packages, including packages for multiple installed PHP versions.

### Configuration validation fails

Do not continue until the reported configuration error is understood. Run the relevant native checks manually, correct the configuration, and rerun `plan` before attempting `apply`.

### A service is not active after the update

Inspect the service journal and configuration:

```bash
sudo systemctl status php8.2-fpm.service
sudo journalctl -u php8.2-fpm.service -b --no-pager
sudo php-fpm8.2 -t
```

Replace the version and service name with the values used on the server.

## Limitations

- The script cannot determine every website's actual PHP runtime from package state alone.
- It does not automatically exclude unused PHP versions.
- It does not provide version-specific package selection in its current form.
- It cannot guarantee application compatibility after a PHP update.
- A successful service restart does not prove that every website is healthy.
- Configuration discovery is best-effort and depends on standard file locations and naming.
- It does not replace backups, staging tests, monitoring, or a rollback plan.
- It does not manage source-built PHP installations or non-APT package managers.

## Production Recommendations

Before running `apply` on a production server:

1. Confirm which PHP versions, FPM pools, and web-server handlers are in use.
2. Run `audit` and save the output for change records.
3. Run `plan` and review the complete APT simulation.
4. Confirm that updates to every listed installed PHP version are acceptable.
5. Verify backups, snapshots, and rollback procedures.
6. Schedule a maintenance window if service restarts may affect traffic.
7. Test representative applications after the update.
8. Monitor PHP-FPM, web-server, application, and system logs.

For servers with multiple PHP versions, treat the operation as coordinated PHP maintenance across the host. If the operational requirement is to patch only one PHP version, implement and test an explicit version filter before using the script for that purpose.

## License

No license is specified by this README. Add the project's intended license and attribution terms before distributing the script.
