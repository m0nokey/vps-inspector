# VPS System Overview Script

A single-script system and file audit tool for Linux servers (Debian; Arch Linux).  
Quickly check system status, search files, or audit packages — all with one command.

- **No dependencies:** Uses only standard tools available in a minimal Linux installation (`bash`, `find`, `awk`, `sed`, `coreutils`, `ip`, `ss`, etc.).
- **No extra installs:** Does not require additional packages like `tree` or `lsd`.
- **One-liner:** Run directly with `curl | bash` for instant results.

> ⚠️ **Security Notice:**  
> Always review any script from the internet before running it on your system!


## Features

* Fast file & directory tree:
  * Show hidden files (`-a`)
  * Limit recursion depth (`-L N`)
  * Filter by include/exclude regex patterns (`-P/-I`)
  * List directories only (`-d`)
  * List directories before files (`--dirsfirst`)
* Detailed file info:
  * Show permissions, owner, group (`-p`, `-u`, `-g`)
  * Classification indicators: dirs/executables/links/archives (`-F`)
  * Show file size (`-z`) and modification time (`-T`)
  * Sort by size or mtime (`--sort-size`, `--sort-mtime`)
  * Display full or relative paths (`-f`)
* Search and filtering:
  * Include or exclude files by name/path/extension (regex)
  * List only files from a specific package (`--package`)
  * Locate binaries or config files by name
* Disk & usage reporting:
  * Show top N largest files in common paths (`-t N`)
  * Disk usage and inode stats for a path (`-r`)
  * Disk/inode usage warnings (>90%)
  * Summarize largest log files
* System snapshot & audit (`-s`):
  * OS name and version
  * Server type (dedicated, container, VM)
  * CPU and memory stats
  * List users and home directories
  * System and user cron jobs
  * Custom and user-defined systemd services
  * Top processes by memory usage
  * Block devices, filesystems, partitions
  * Broken symlinks and zombie processes
  * Network info: interfaces, IPs, routes, DNS, open ports
  * NAT rules (iptables/ip6tables)
  * Docker containers (if installed)
  * Package install/upgrade history (`/var/log/dpkg.log*`)

## Usage
No installation, no extra packages needed — run any audit/check/search directly from your shell with one line:

### Get a full system snapshot:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -s
```
```bash
# system snapshot
os: debian 11 (bullseye)
server type: container (docker)
cpu cores: 4
memory: 1.2G/4.0G

# users & home directory trees
user: alice
    alice-folder
user: bob
    bob-folder

# cron jobs
system crontab (/etc/crontab & /etc/cron.d)
0 5 * * * root   apt update && apt upgrade -y
file: daily-backup
30 2 * * * backup  /usr/local/bin/backup.sh
user crontabs
user: alice
0 6 * * * backup.sh

# custom system services
myservice.service

# user-defined systemd services
user: alice
  user-service.service

# top 10 by %mem
alice    1234  5.0  25.3  512000 102400 ?   Sl   10:00  0:05 /usr/bin/foo
bob      2345  3.2  10.1  256000  40960 ?   Sl   10:01  0:02 /usr/bin/bar

# block devices
NAME   SIZE TYPE MODEL
sda    40G  disk  

# filesystems & partitions
NAME   SIZE FSTYPE MOUNTPOINT
sda1   40G  ext4   /

# disk usage warnings (>90%)
(none)

# inode usage warnings (>90%)
(none)

# top 10 largest logs
12M  /var/log/syslog
5M   /var/log/auth.log

# broken symlinks under /usr
(none)

# zombie processes
(none)

# interface details
primary interface:   eth0
ipv4 address:        192.168.1.10
gateway:             192.168.1.1

# dns resolver
resolver service:   systemd-resolved

# nameservers
    8.8.8.8
    8.8.4.4

# routes
default via 192.168.1.1 dev eth0

# listening tcp/udp ports
Netid State   Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN  0      128    0.0.0.0:22         0.0.0.0:*         sshd

# ipv4 nat table & rules
(none)

# ipv6 nat table & rules
(none)

# docker containers
CONTAINER ID   IMAGE          COMMAND     STATUS    NAMES
abc123         ubuntu:20.04   "/bin/bash" Up 2h     web

# package install/upgrade history
date       time    action  package arch   old_version new_version  status
2025-06-20 12:00   install vim     amd64  2:0.8.0    2:0.8.1       + 
```

### Check pkg paths:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- --package openssh-server
```
```bash
/
├── etc
│  ├── default
│  │  ├── ssh
│  ├── init.d
│  │  ├── ssh
│  ├── pam.d
│  │  ├── sshd
│  ├── runit
│  │  └── runsvdir
│  │     └── default
│  ├── ssh
│  │  ├── moduli
│  │  ├── sshd_config.d
│  ├── sv
│  │  └── ssh
│  │     ├── finish
│  │     ├── log
│  │     │  └── run
│  │     └── run
│  ├── ufw
│  │  └── applications.d
│  │     └── openssh-server
├── lib -> usr/lib 
├── usr
│  ├── lib
│  │  ├── openssh
│  │  │  ├── ssh-session-cleanup
│  ├── sbin
│  │  ├── sshd
│  ├── share
│  │  ├── apport
│  │  │  └── package-hooks
│  │  │     ├── openssh-server.py
│  │  ├── doc
│  │  │  ├── openssh-client
│  │  │  │  ├── examples
│  │  │  │  │  └── ssh-session-cleanup.service
│  │  │  ├── openssh-server -> openssh-client 
│  │  ├── lintian
│  │  │  ├── overrides
│  │  │  │  ├── openssh-server
│  │  ├── man
│  │  │  ├── man5
│  │  │  │  ├── authorized_keys.5.gz -> ../man8/sshd.8.gz 
│  │  │  │  ├── moduli.5.gz
│  │  │  │  ├── sshd_config.5.gz
│  │  │  ├── man8
│  │  │  │  ├── sshd.8.gz
│  │  ├── openssh
│  │  │  ├── sshd_config
│  │  │  └── sshd_config.md5sum
│  │  ├── runit
│  │  │  └── meta
│  │  │     └── ssh
│  │  │        └── installed
├── var
│  ├── log
│  │  ├── runit
│  │  │  └── ssh
```

### List all files and directories (including hidden) in /etc up to 2 levels:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -a -L 2 /etc
```
### Show the top 5 largest files in /var/log, /home, /tmp:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -t 5
```
### List only .conf files anywhere in /etc:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -P '\.conf$' /etc
```
### See more options and examples:
```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -h
```


## license

licensed under the mit license. see [license](./LICENSE) for details.
