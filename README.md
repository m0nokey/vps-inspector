# vps system overview script

this script is a helper tool for vps (mainly debian) to quickly view the system status with a single command. it uses only standard tools available in a minimal linux installation (bash, find, awk, sed, coreutils, ip, ss, etc.) and does not require any additional packages like `tree`.

## features

* list files and directories with optional filters (hidden, depth, include/exclude patterns)
* display permissions, owners, groups, and classification indicators
* show top n largest files in common paths (`/var/log`, `/home`, `/tmp`)
* generate disk usage and inode reports with `df`
* take a full system snapshot:

  * os name and version
  * server type (dedicated, container, or vm)
  * cpu cores and memory usage
  * users’ home directory trees
  * system and user cron jobs
  * custom and user-defined systemd services
  * top processes by memory
  * block devices and filesystems
  * disk and inode usage warnings
  * largest log files
  * broken symlinks and zombie processes
  * network interfaces, routes, dns resolver, listening ports
  * iptables/nft nat rules
  * docker container list (if docker is installed)
  * package install/upgrade history (from `/var/log/dpkg.log*`)

## installation

to install, download the raw script and run it with bash:

```bash
curl -sSfL --tlsv1.3 --http2 --proto '=https' "https://raw.githubusercontent.com/m0nokey/vps-inspector/main/vps-inspector.sh" | bash -s -- -s
```

**example full snapshot output:**

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

## usage

```bash
./script.sh [options] [path|package|file]
```

## license

licensed under the mit license. see [license](./LICENSE) for details.
