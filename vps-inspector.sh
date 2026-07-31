#!/usr/bin/env bash
export LC_ALL=C

# default options
SHOW_HIDDEN=0; ONLY_DIRS=0; MAX_DEPTH=999
INCLUDE=(); EXCLUDE=()
FULL_PATH=0; CLASSIFY=0
SHOW_PERM=0; SHOW_USER=0; SHOW_GROUP=0
DIRS_FIRST=0; PACKAGE_MODE=0; FILE_MODE=0
TOP_N=0; DFREPORT=0; SNAPSHOT=0; ALL_REPORT=0
CPU_REPORT=0; MEMORY_REPORT=0; DISK_REPORT=0; LOAD_REPORT=0; UPTIME_REPORT=0
NETWORK_REPORT=0; PORTS_REPORT=0; USERS_REPORT=0; DOCKER_REPORT=0
RUNTIME_REPORT=0
DOCKER_CONTAINER=""
SHOW_SIZE=0; SORT_SIZE=0
SHOW_TIME=0; SORT_MTIME=0
TARGET=""; PKGFILES=(); FILE_PATH=""
declare -a SIZES=()
COMMON_PATHS=(/var/log /home /tmp)

# colors & counters
RESET=$'\e[0m'; DIR_COL=$'\e[1;34m'; LINK_COL=$'\e[1;36m'
EXEC_COL=$'\e[1;32m'; ARCH_COL=$'\e[1;31m'; ORANGE=$'\e[38;5;214m'
COUNT_DIRS=0; COUNT_FILES=0

MAXUSER=$(awk -F: '{if(length($1)>max) max=length($1)} END{print max+0}' /etc/passwd)
MAXGROUP=$(awk -F: '{if(length($1)>max) max=length($1)} END{print max+0}' /etc/group)
MAXPERM=10
MAXSIZE=9

# indent: add or remove N leading spaces per line using sed
# Usage: indent + N   # add N spaces
#        indent - N   # remove up to N spaces
indent() {
    MODE="$1"
    NUM="$2"
    if [[ "$MODE" == "+" ]]; then
        sed "s/^/$(printf '%*s' "$NUM")/"
    elif [[ "$MODE" == "-" ]]; then
        sed -E "s/^ {0,$NUM}//"
    fi
}

# usage information
usage() {
    cat <<EOF | indent - 4 >&2
    Usage: $0 [options] [path|package|file]

    Options:
      -a                   Show hidden files
      -d                   Show directories only
      -L depth             Set recursion depth (default unlimited)
      -P include_regex     Include only paths matching regex
      -I exclude_regex     Exclude paths matching regex
      -f                   Print full paths instead of names
      -F                   Append indicators: '/' for dirs, '*' for executables, '@' for links, '#' for archives
      -p                   Show permissions before name
      -u                   Show owner before name
      -g                   Show group before name
      --dirsfirst          List directories before files
      --package            Force package mode (list all files from package)
      -T, --time           Show last modification time before name
      -z, --size           Show file/directory size before name
      --sort-size          Sort entries by size (largest first)
      --sort-mtime         Sort entries by modification time (newest first)
      -t N, --top N        Show top N largest files in /var/log,/home,/tmp
      -r, --dfreport       Show df -h and df -i for target
      -s, --snapshot       Quick system snapshot
      --all                Show full system snapshot and Docker overview if available
      --cpu                Show CPU information
      --memory             Show memory information
      --disk               Show disk information
      --load               Show load average
      --uptime             Show uptime
      --runtime            Show virtualization and cgroup runtime hints
      --network            Show network information
      --ports              Show listening ports
      --users              Show users summary
      --docker             Show Docker overview if Docker is installed
      --docker-container ID|NAME
                           Show deep snapshot for one Docker container
      -h, --help           Show this help and exit

    Examples:
      # 1. Show all files and directories, including hidden ones (starting with .)
      $0 -a

      # 2. Show only directories inside /etc, up to 2 levels deep
      $0 -d -L 2 /etc

      # 3. Find only .conf files (configs) in the current folder (NOT recursive)
      $0 -P '\.conf$'

      # 4. Find all .conf files anywhere in /etc, show minimal tree with only matches (up to 4 levels deep)
      $0 -L 4 -P '\.conf$' /etc

      # 5. Show all .conf files under any nginx subfolders (useful for finding all nginx configs)
      $0 -P 'nginx.*\.conf$' /etc

      # 6. OR: search only in letsencrypt/renewal for .conf files (for example, certificates)
      $0 -P 'letsencrypt/renewal/.*\.conf$' /etc

      # 7. Show all files EXCEPT those inside /bin (exclude by pattern)
      $0 -I '/bin'

      # 8. Show tree with full paths and file type markers:
      #    (directories: /, executables: *, symlinks: @, archives: #)
      $0 -f -F

      # 9. Get a flat list of full paths to all .conf files in /etc (no tree view)
      $0 -f -P '\.conf$' /etc

      # 10. Find only hidden .sh scripts (like .bashrc) in your home folder
      $0 -a -P '\.sh$' ~/

      # 11. Show the top 5 largest files in standard locations (/var/log, /home, /tmp)
      $0 -t 5

      # 12. Show disk usage and inode report for /var
      $0 -r /var

      # 13. Quick snapshot of the whole system (OS, memory, users, services, ports, top 10 processes, and more)
      $0 -s

      # 14. Show minimal tree of folders where there is at least one .log file (useful for finding logs)
      $0 -P '\.log$' /var/log

      # 15. Use --package option to list all files from a package (example: netcat-openbsd)
      $0 --package netcat-openbsd

      # 16. Search in all folders, including hidden ones, up to depth 3, only .json files
      $0 -a -L 3 -P '\.json$' /

      # 17. Show files in /var sorted by size, with owner/group/permissions/size shown
      $0 --sort-size -p -u -g -z /var

      # 18. Show files in /tmp sorted by modification time (newest first), show time and size
      $0 --sort-mtime -T -z /tmp

    # Pattern tips:
    # -P 'regex'   matches ANY part of the file or folder path.
    #              To match only filenames, use for example: '\.conf$'
    #              To match in subfolders: 'nginx.*\.conf$'
    # -I 'regex'   excludes anything that matches the pattern

    # Regex notes:
    #   . * ? + [ ] ( ) ^ $ | have special meaning in regex
    #   To match a dot literally, use '\.'
    #   Use | for OR (example: 'nginx|letsencrypt')
    #   To match "in a folder AND with an extension", combine patterns: 'nginx.*\.conf$'

    # If unsure, run with -h or --help for full help and tips!
EOF
    exit 1
}

# define tree function
print_tree() {
    local DIR="$1" DEPTH="$2" PREFIX="$3"
    (( DEPTH > MAX_DEPTH )) && return

    local HIDE_ARGS=()
    (( SHOW_HIDDEN == 0 )) && HIDE_ARGS=(-not -name '.*')

    mapfile -d '' -t ENTRIES < <(find "$DIR" -mindepth 1 -maxdepth 1 "${HIDE_ARGS[@]}" -print0 2>/dev/null | sort -z --version-sort --ignore-case)

    if (( DIRS_FIRST )); then
        local DLIST=() SLINKDIRS=() FLIST=()
        for E in "${ENTRIES[@]}"; do
            if [[ -d $E && ! -L $E ]]; then
                DLIST+=("$E")
            elif [[ -L $E && -d $E ]]; then
                SLINKDIRS+=("$E")
            else
                FLIST+=("$E")
            fi
        done
        ENTRIES=("${DLIST[@]}" "${SLINKDIRS[@]}" "${FLIST[@]}")
    fi

    if (( SORT_SIZE && SHOW_SIZE )); then
        local -a TMP_SORT=()
        for E in "${ENTRIES[@]}"; do
            local S=0
            if [[ -d $E ]]; then
                S=$(du -sb "$E" 2>/dev/null | awk '{print $1}')
            else
                S=$(stat -c %s "$E" 2>/dev/null)
            fi
            # use a null separator for absolute correctness of names!
            TMP_SORT+=( "$S"$'\t'"$E" )
        done
        # sort and write only filenames in ENTRIES (with zero separator)
        ENTRIES=()
        while IFS=$'\t' read -r _SIZE _NAME; do
            ENTRIES+=( "$_NAME" )
        done < <(printf '%s\0' "${TMP_SORT[@]}" | sort -z -r -n | tr '\0' '\n')
        unset TMP_SORT
    fi

    if (( SORT_MTIME )); then
        local -a TMP_SORT=()
        for E in "${ENTRIES[@]}"; do
            local T=0
            T=$(stat -c %Y "$E" 2>/dev/null)
            TMP_SORT+=( "$T"$'\t'"$E" )
        done
        # sort by time (new on top)
        ENTRIES=()
        while IFS=$'\t' read -r _T _NAME; do
            ENTRIES+=( "$_NAME" )
        done < <(printf '%s\0' "${TMP_SORT[@]}" | sort -z -r -n | tr '\0' '\n')
        unset TMP_SORT
    fi

    local TOTAL=${#ENTRIES[@]} IDX=0
    for ENTRY in "${ENTRIES[@]}"; do
        [[ -z "$ENTRY" ]] && continue
        (( IDX++ ))
        if (( FILE_MODE )); then
            [[ "$(realpath "$ENTRY")" != "$FILE_PATH" ]] && continue
        fi

        local NAME=${ENTRY##*/}
        if (( PACKAGE_MODE )) && [[ -z ${PKGSET[$ENTRY]} ]]; then continue; fi
        if (( ${#INCLUDE[@]} )); then
            local OK=0
            for RX in "${INCLUDE[@]}"; do [[ $ENTRY =~ $RX ]] && OK=1; done
            (( OK == 0 )) && continue
        fi
        if (( ${#EXCLUDE[@]} )); then
            local SKIP=0
            for RX in "${EXCLUDE[@]}"; do [[ $ENTRY =~ $RX ]] && SKIP=1; done
            (( SKIP )) && continue
        fi
        if (( ONLY_DIRS )) && [[ ! -d $ENTRY ]]; then continue; fi

        if (( TOP_N > 0 )); then
            local SZ=$(stat -c '%s' "$ENTRY" 2>/dev/null || echo 0)
            SIZES+=("$SZ|$ENTRY")
        fi

        if read -r PERM OWN GRP < <(stat -c '%A %U %G' "$ENTRY" 2>/dev/null); then
            :
        else
            PERM='' ; OWN='' ; GRP=''
        fi
        PERM=${PERM:-'-'}
        OWN=${OWN:-'-'}
        GRP=${GRP:-'-'}

        # Get the date (if necessary)
        local DATE=""
        if (( SHOW_TIME )); then
            DATE=$(stat -c '%y' "$ENTRY" 2>/dev/null | cut -c1-19)
            DATE=${DATE:-'-'}
        fi

        local PTR CHILD
        if (( IDX == TOTAL )); then
            PTR='└──'; CHILD='   '
        else
            PTR='├──'; CHILD='│  '
        fi

        local SUF=""
        if (( CLASSIFY )); then
            if [[ -L $ENTRY ]]; then
                SUF='@'
            elif [[ -d $ENTRY ]]; then
                SUF='/'
            elif [[ -x $ENTRY ]]; then
                SUF='*'
            elif [[ $NAME =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]]; then
                SUF='#'
            fi
        fi

        # Form an ls-like template, with the date BEFORE the name!
        local FMT="" printf_args=()
        (( SHOW_PERM ))  && { FMT+="%-${MAXPERM}s ";  printf_args+=("$PERM"); }
        (( SHOW_USER ))  && { FMT+="%-${MAXUSER}s ";  printf_args+=("$OWN"); }
        (( SHOW_GROUP )) && { FMT+="%-${MAXGROUP}s "; printf_args+=("$GRP"); }
        if (( SHOW_SIZE )); then
            local SIZE=0 SIZEDISP=""
            if [[ -d $ENTRY ]]; then
                SIZE=$(du -sb "$ENTRY" 2>/dev/null | awk '{print $1}')
            else
                SIZE=$(stat -c %s "$ENTRY" 2>/dev/null)
            fi
            SIZEDISP=$(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE}B")
            SIZEDISP=${SIZEDISP:-'-'}
            FMT+="%-${MAXSIZE}s "
            printf_args+=("$SIZEDISP")
        fi
        (( SHOW_TIME )) && { FMT+="%-20s "; printf_args+=("$DATE"); }

        local DISP="$NAME"
        (( FULL_PATH )) && DISP="$ENTRY"

        # Symlink
        if [[ -L $ENTRY ]]; then
            (( COUNT_FILES++ ))
            local REL COL2
            REL=$(readlink "$ENTRY")
            if [[ -d $ENTRY ]]; then COL2=$DIR_COL
            elif [[ -x $ENTRY ]]; then COL2=$EXEC_COL
            elif [[ $REL =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]]; then COL2=$ARCH_COL
            else COL2=$RESET
            fi
            printf "$FMT%s%s %b%s%b -> %b%s%b %b%s%b\n" "${printf_args[@]}" "${PREFIX}${PTR}" "$LINK_COL" "$DISP" "$RESET" "$COL2" "$REL" "$RESET" "$LINK_COL" "$SUF" "$RESET"
            continue
        fi

        if [[ -d $ENTRY && ! -r $ENTRY ]]; then
            (( COUNT_DIRS++ ))
            local outstr
            printf -v outstr "$FMT%s%s %b%s%b" "${printf_args[@]}" "${PREFIX}${PTR}" "$DIR_COL" "$DISP" "$RESET"
            echo -e "$outstr ${ORANGE}[permission denied]${RESET}"
            continue
        fi

        # Colors for others
        local COL
        if [[ -d $ENTRY ]]; then
            COL=$DIR_COL
            (( COUNT_DIRS++ ))
        elif [[ -x $ENTRY ]]; then
            COL=$EXEC_COL
            (( COUNT_FILES++ ))
        elif [[ $NAME =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]]; then
            COL=$ARCH_COL
            (( COUNT_FILES++ ))
        else
            COL=$RESET
            (( COUNT_FILES++ ))
        fi

        printf "$FMT%s%s %b%s%b%b%s%b\n" "${printf_args[@]}" "${PREFIX}${PTR}" "$COL" "$DISP" "$RESET" "$COL" "$SUF" "$RESET"

        [[ -d $ENTRY ]] && print_tree "$ENTRY" $((DEPTH+1)) "${PREFIX}${CHILD}"
    done
}

print_min_tree() {
    local ROOT="$1"
    local MAX_DEPTH="$2"
    local -a REGEXES=("${INCLUDE[@]}")

    local FIND_ARGS=()
    (( SHOW_HIDDEN == 0 )) && FIND_ARGS+=('!' -name '.*')
    FIND_ARGS+=(-type f)
    (( MAX_DEPTH < 999 )) && FIND_ARGS+=(-maxdepth "$MAX_DEPTH")

    local PATTERN=""
    for RX in "${REGEXES[@]}"; do
        [[ -n "$PATTERN" ]] && PATTERN="$PATTERN|"
        PATTERN="$PATTERN$RX"
    done
    [[ -z "$PATTERN" ]] && PATTERN="."

    mapfile -t MATCHED < <(find "$ROOT" "${FIND_ARGS[@]}" -regextype posix-extended -regex ".*($PATTERN)" 2>/dev/null | sort -V)

    # if there's no match, just the root
    if [[ ${#MATCHED[@]} -eq 0 ]]; then
        printf '%b%s%b\n' "$DIR_COL" "$ROOT" "$RESET"
        echo "No matching files"
        printf '0 directories, 0 files\n'
        return 0
    fi

    declare -A PATHSET=()
    for F in "${MATCHED[@]}"; do
        P="$F"
        while [[ "$P" != "$ROOT" && "$P" != "/" ]]; do
            PATHSET["$P"]=1
            P="$(dirname "$P")"
        done
        PATHSET["$ROOT"]=1
    done

    print_min_tree_recurse() {
        local DIR="$1" DEPTH="$2" PREFIX="$3"
        (( DEPTH > MAX_DEPTH )) && return

        local ENTRIES=()
        while IFS= read -r -d $'\0' ENTRY; do
            [[ -n "${PATHSET[$ENTRY]}" ]] && ENTRIES+=("$ENTRY")
        done < <(find "$DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)

        local TOTAL=${#ENTRIES[@]} IDX=0
        for ENTRY in "${ENTRIES[@]}"; do
            (( IDX++ ))
            local NAME="${ENTRY##*/}"
            local IS_LAST=0
            (( IDX == TOTAL )) && IS_LAST=1

            local PTR CHILD
            if (( IS_LAST )); then PTR='└──'; CHILD='   '; else PTR='├──'; CHILD='│  '; fi

            if [[ -d $ENTRY ]]; then
                printf "%s%s %b%s%b\n" "$PREFIX" "$PTR" "$DIR_COL" "$NAME" "$RESET"
                print_min_tree_recurse "$ENTRY" $((DEPTH+1)) "$PREFIX$CHILD"
                ((COUNT_DIRS++))
            else
                printf "%s%s %s\n" "$PREFIX" "$PTR" "$NAME"
                ((COUNT_FILES++))
            fi
        done
    }

    printf '%b%s%b\n' "$DIR_COL" "$ROOT" "$RESET"
    print_min_tree_recurse "$ROOT" 1 ""
    echo
    printf '%d directories, %d files\n' "$COUNT_DIRS" "$COUNT_FILES"
}

# wrapper to call print_tree from anywhere
parse_tree() {
    print_tree "$@"
}

# quick system snapshot
snapshot() {
    echo -e "# System"
    {
        if [[ -r /etc/os-release ]]; then
            . /etc/os-release
            echo "OS: $PRETTY_NAME"
        else
            echo "OS: unknown"
        fi

            # determine server type: dedicated, container or VM
            if command -v systemd-detect-virt &>/dev/null; then
                VT=$(systemd-detect-virt)
                case "$VT" in
                    none)
                        echo "Server type: Dedicated server" ;;
                    lxc|docker|openvz|podman|systemd-nspawn)
                        echo "Server type: Container ($VT)" ;;
                    *)
                        echo "Server type: Virtual machine ($VT)" ;;
                esac
            elif [[ -f /.dockerenv ]]; then
                echo "Server type: Container (docker)"
            else
                echo "Server type: unknown"
            fi

            echo "Cgroup filesystem: $(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
            if [[ -r /proc/self/cgroup ]]; then
                if grep -q '^0::' /proc/self/cgroup 2>/dev/null; then
                    echo "Cgroup mode: unified/v2"
                else
                    echo "Cgroup mode: legacy/v1 or hybrid"
                fi
            fi

            echo "Current time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            UPTIME_SECONDS="$(cut -d'.' -f1 /proc/uptime 2>/dev/null | cut -d' ' -f1 || echo 0)"
            echo "Uptime: $(format_uptime "$UPTIME_SECONDS")"

    } | indent + 4

    echo -e "\n# Compute"
    echo "    CPU:"
    cpu_metrics | indent + 4
    echo
    echo "    Load:"
    load_metrics | indent + 4
    echo
    echo "    Tasks and processes:"
    tasks_metrics | indent + 4
    echo
    echo "    Top 10 by %MEM:"
    top_memory_processes | indent + 4

    echo -e "\n# Memory"
    memory_metrics

    echo -e "\n# Storage"
    storage_snapshot
    network_snapshot
    users_report

    # Users & Home directory trees
    echo -e "\n# Users & Home directory trees"
    {
        # gather all real users (uid ≥1000)
        mapfile -t USER_HOMES < <(
            awk -F: '$3>=1000 && $7 !~ /(nologin|false)$/ { print $1 ":" $6 }' /etc/passwd
        )

        # if list is empty and we are root, add root:/root
        if (( ${#USER_HOMES[@]} == 0 )) && (( EUID == 0 )); then
            USER_HOMES=( "root:/root" )
        fi

        # for each user print tree showing hidden files
        for UH in "${USER_HOMES[@]}"; do
            U_NAME=${UH%%:*}
            U_HOME=${UH#*:}

            echo -e "${DIR_COL}User: $U_NAME${RESET}"
            if [[ -d "$U_HOME" ]]; then
                SHOW_HIDDEN=1 print_tree "$U_HOME" 1 ""
            else
                echo -e "    ${ORANGE}(No home directory)${RESET}"
            fi
            echo
        done
    } | indent + 4

    # cron jobs
    echo -e "\n# Cron jobs"
    {
        echo "System crontab (/etc/crontab & /etc/cron.d)"
        grep -Ev '^\s*#' /etc/crontab 2>/dev/null

        for CRON_FILE in /etc/cron.d/*; do
            [[ -f $CRON_FILE ]] || continue
            echo
            echo "File: $(basename "$CRON_FILE")"
            grep -Ev '^\s*#' "$CRON_FILE" 2>/dev/null
        done

        echo
        echo "USER CRONTABS"
        awk -F: '$3>=1000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd \
        | while read -r C_USER; do
            echo
            echo "User: $C_USER"
            crontab -l -u "$C_USER" 2>/dev/null || echo "(none)"
        done
    } | indent + 4

    # custom system services
    echo -e "\n# Custom system services"
    {
        if [[ -d /etc/systemd/system ]]; then
            find /etc/systemd/system -maxdepth 1 -type f -name '*.service' -exec basename {} \;
        else
            echo "(systemd directory not found)"
        fi
    } | indent + 4

    # user-defined systemd services
    echo -e "\n# User-defined systemd services"
    {
        if have systemctl; then
            awk -F: '$3>=1000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd \
            | while read -r S_USER; do
                echo "User: $S_USER"
                su - "$S_USER" -c 'systemctl --user list-unit-files --type=service --no-pager' 2>/dev/null || echo "(none)"
                echo
            done
        else
            echo "systemctl not found"
        fi
    } | indent + 4

    echo -e "\n# Broken symlinks under /usr"
    {
        mapfile -t SYMLINKS < <(find /usr -xtype l)
        if (( ${#SYMLINKS[@]} )); then
            printf "%s\n" "${SYMLINKS[@]}"
        else
            echo "(none)"
        fi
    } | indent + 4

    echo -e "\n# Zombie processes"
    {
        mapfile -t ZOMBIES < <(ps -ef | awk '$8=="Z"')
        if (( ${#ZOMBIES[@]} )); then
            printf "%s\n" "${ZOMBIES[@]}"
        else
            echo "(none)"
        fi
    } | indent + 4

    docker_snapshot_report

    echo -e "\n# Package install/upgrade history"
    {
        printf "%-10s %-8s %-8s %-15s %-5s %-12s %-12s %s\n" "DATE" "TIME" "ACTION" "PACKAGE" "ARCH" "OLD_VERSION" "NEW_VERSION" "STATUS"

        if have dpkg-query; then
            grep -hE ' install | upgrade ' /var/log/dpkg.log* 2>/dev/null \
              | awk '{
                    n = split($4,a,":");
                    pkg  = a[1];
                    arch = a[2];
                    printf "%s %s %s %s %s %s %s\n", $1, $2, $3, pkg, arch, $5, $6
                }' \
              | sort -k1,1 -k2,2 \
              | while read DATE TIME ACTION PACKAGE ARCH OLD_REV NEW_REV; do
                    STATUS=$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null | grep -q "installed" && echo "+" || echo "-")
                    printf "%-10s %-8s %-8s %-15s %-5s %-12s %-12s %s\n" "$DATE" "$TIME" "$ACTION" "$PACKAGE" "$ARCH" "$OLD_REV" "$NEW_REV" "$STATUS"
                done
        else
            echo "dpkg-query not found"
        fi
    } | {
        if have column; then column -t; else cat; fi
    } | indent + 4
}

have() {
    command -v "$1" >/dev/null 2>&1
}

field() {
    printf "    %-20s %s\n" "$1:" "$2"
}

kib_to_human() {
    awk -v kib="${1:-0}" 'BEGIN {
        mib = kib / 1024;
        gib = mib / 1024;
        if (gib >= 1) printf "%.2f GiB", gib;
        else if (mib >= 1) printf "%.2f MiB", mib;
        else printf "%d KiB", kib;
    }'
}

bytes_to_human() {
    awk -v bytes="${1:-0}" 'BEGIN {
        kib = bytes / 1024;
        mib = kib / 1024;
        gib = mib / 1024;
        tib = gib / 1024;
        if (tib >= 1) printf "%.2f TiB", tib;
        else if (gib >= 1) printf "%.2f GiB", gib;
        else if (mib >= 1) printf "%.2f MiB", mib;
        else if (kib >= 1) printf "%.2f KiB", kib;
        else printf "%d B", bytes;
    }'
}

format_uptime() {
    local seconds="${1:-0}"
    printf "%d days, %d hours, %d minutes" \
        "$((seconds / 86400))" \
        "$(((seconds % 86400) / 3600))" \
        "$(((seconds % 3600) / 60))"
}

cpu_metrics() {
    local before after
    local user nice system idle iowait irq softirq steal
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
    local user_pct nice_pct system_pct idle_pct iowait_pct irq_pct
    local softirq_pct steal_pct
    if have nproc; then
        field "CPU cores" "$(nproc)"
    else
        field "CPU cores" "(unknown)"
    fi

    if [[ -r /proc/stat ]]; then
        read -r user nice system idle iowait irq softirq steal < <(
            awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9; exit}' /proc/stat
        )
        sleep 1
        read -r user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 < <(
            awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9; exit}' /proc/stat
        )

        before="$user $nice $system $idle $iowait $irq $softirq $steal"
        after="$user2 $nice2 $system2 $idle2 $iowait2 $irq2 $softirq2 $steal2"
        read -r user_pct nice_pct system_pct idle_pct iowait_pct irq_pct \
            softirq_pct steal_pct < <(
            awk -v before="$before" -v after="$after" '
                BEGIN {
                    split(before, b)
                    split(after, a)
                    total = 0
                    for (i = 1; i <= 8; i++) total += a[i] - b[i]
                    if (total <= 0) total = 1
                    for (i = 1; i <= 8; i++) printf "%.1f%s", (a[i] - b[i]) * 100 / total, (i == 8 ? "\n" : " ")
                }
            '
        )
        field "User time" "${user_pct:-0.0}%"
        field "System time" "${system_pct:-0.0}%"
        field "Nice process time" "${nice_pct:-0.0}%"
        field "Idle time" "${idle_pct:-0.0}%"
        field "I/O wait time" "${iowait_pct:-0.0}%"
        field "Hardware interrupt time" "${irq_pct:-0.0}%"
        field "Software interrupt time" "${softirq_pct:-0.0}%"
        field "Steal time" "${steal_pct:-0.0}%"
    else
        field "CPU timing" " /proc/stat unavailable"
    fi
}

cpu_report() {
    echo -e "\n# CPU"
    cpu_metrics
}

memory_metrics() {
    local total free buffers cached avail used swap_total swap_free swap_used
    total="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    free="$(awk '/^MemFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    buffers="$(awk '/^Buffers:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    cached="$(awk '/^Cached:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    avail="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    used="$((total - avail))"
    swap_total="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_free="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_used="$((swap_total - swap_free))"
    field "Total memory" "$(kib_to_human "$total")"
    field "Free memory" "$(kib_to_human "$free")"
    field "Used memory" "$(kib_to_human "$used")"
    field "Buffers" "$(kib_to_human "$buffers")"
    field "Cached memory" "$(kib_to_human "$cached")"
    field "Available memory" "$(kib_to_human "$avail")"
    field "Swap total" "$(kib_to_human "$swap_total")"
    field "Swap free" "$(kib_to_human "$swap_free")"
    field "Swap used" "$(kib_to_human "$swap_used")"
}

memory_report() {
    echo -e "\n# Memory"
    memory_metrics
}

tasks_metrics() {
    local total running sleeping stopped zombie
    if ! have ps; then
        field "Process statistics" "ps is not available"
        return 0
    fi

    read -r total running sleeping stopped zombie < <(
        ps -e -o stat= 2>/dev/null | awk '
            {
                total++
                state = substr($1, 1, 1)
                if (state == "R") running++
                else if (state == "S" || state == "D" || state == "I") sleeping++
                else if (state == "T" || state == "t") stopped++
                else if (state == "Z") zombie++
            }
            END { print total + 0, running + 0, sleeping + 0, stopped + 0, zombie + 0 }
        '
    )

    field "Total tasks" "${total:-0}"
    field "Running" "${running:-0}"
    field "Sleeping" "${sleeping:-0}"
    field "Stopped" "${stopped:-0}"
    field "Zombie" "${zombie:-0}"
}

tasks_report() {
    echo -e "\n# Tasks"
    tasks_metrics
}

top_memory_processes() {
    if ps -eo user,pid,pcpu,pmem,vsz,rss,stat,time,comm >/dev/null 2>&1; then
        printf "%-10s %-7s %-6s %-6s %-8s %-8s %-6s %-8s %s\n" \
            "USER" "PID" "%CPU" "%MEM" "VSZ" "RSS" "STAT" "TIME" "COMMAND"
        ps -eo user=,pid=,pcpu=,pmem=,vsz=,rss=,stat=,time=,comm= --sort=-pmem \
            | head -n 10 \
            | awk '{printf "%-10s %-7s %-6s %-6s %-8s %-8s %-6s %-8s %s\n", \
                $1, $2, $3, $4, $5, $6, $7, $8, $9}'
        return 0
    fi

    printf "%-10s %-7s %-6s %-6s %-8s %-8s %-6s %-8s %s\n" \
        "USER" "PID" "%CPU" "%MEM" "VSZ" "RSS" "STAT" "TIME" "COMMAND"
    if ps aux >/dev/null 2>&1; then
        ps aux | tail -n +2 | head -n 10 \
            | awk '{command=$11; for (i=12; i<=NF; i++) command=command " " $i; \
                printf "%-10s %-7s %-6s %-6s %-8s %-8s %-6s %-8s %s\n", \
                $1, $2, $3, $4, $5, $6, $8, $10, command}'
    else
        echo "ps output unavailable"
    fi
}

storage_snapshot() {
    local disk_names disk row name size type fstype mount model free_space
    local read_ops write_ops io_time_ms errs kernel_matches

    echo "    Devices and filesystems:"
    if ! have lsblk; then
        echo "        lsblk not found"
        return 0
    fi

    printf "        %-10s %-8s %-6s %-8s %-16s %-14s %s\n" \
        "NAME" "SIZE" "TYPE" "FSTYPE" "MOUNTPOINT" "FREE SPACE" "MODEL"
    while IFS= read -r row; do
        name="$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<< "$row")"
        size="$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<< "$row")"
        type="$(sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        fstype="$(sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        mount="$(sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p' <<< "$row")"
        [[ -n "$name" ]] || continue
        free_space=""
        model=""
        if [[ "$type" == "disk" ]]; then
            model="$(lsblk -dno MODEL "/dev/$name" 2>/dev/null || true)"
        fi
        if [[ -n "$mount" ]] && have df; then
            free_space="$(df -kP "$mount" 2>/dev/null \
                | awk 'NR == 2 {gsub("%", "", $5); printf "%.2fG", $4 / 1024 / 1024}')"
        fi
        printf "        %-10s %-8s %-6s %-8s %-16s %-14s %s\n" \
            "$name" "$size" "$type" "$fstype" "$mount" \
            "$free_space" "$model"
    done < <(lsblk -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null)

    disk_names="$(lsblk -d -n -o NAME,TYPE 2>/dev/null \
        | awk '$2 == "disk" {print $1}')"
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        echo
        echo "    I/O activity:"
        echo "        Device: /dev/$disk"
        read -r read_ops write_ops io_time_ms < <(disk_activity_delta "$disk")
        printf "        Read operations:  %s\n" "$read_ops"
        printf "        Write operations: %s\n" "$write_ops"
        printf "        I/O time delta:   %s ms\n" "$io_time_ms"

    done <<< "$disk_names"

    echo
    echo "    Kernel messages:"
    kernel_matches="N/A"
    if [[ -n "$disk_names" ]]; then
        kernel_matches=0
        while IFS= read -r disk; do
            [[ -n "$disk" ]] || continue
            errs="$(disk_kernel_error_matches "$disk")"
            if [[ "$errs" == "N/A" ]]; then
                kernel_matches="N/A"
                break
            fi
            kernel_matches=$((kernel_matches + errs))
        done <<< "$disk_names"
    fi
    printf "        Kernel error matches: %s\n" "$kernel_matches"

    echo
    echo "    Disk usage warnings (>90%):"
    if have df; then
        df -h | awk '$5+0 > 90 {print "        WARN:", $0}'
        [[ "$(df -h | awk '$5+0 > 90 {count++} END {print count + 0}')" -gt 0 ]] \
            || echo "        (none)"
    else
        echo "        df not found"
    fi

    echo
    echo "    Inode usage warnings (>90%):"
    if have df; then
        df -i | awk '$5+0 > 90 {print "        WARN: inode usage high:", $0}'
        [[ "$(df -i | awk '$5+0 > 90 {count++} END {print count + 0}')" -gt 0 ]] \
            || echo "        (none)"
    else
        echo "        df not found"
    fi

    echo
    echo "    Largest logs:"
    du -sh /var/log/* 2>/dev/null \
        | sort -hr \
        | head -n 10 \
        | awk '{size=$1; $1=""; sub(/^ */, ""); printf "        %-8s %s\n", size, $0}'
}

disk_metrics() {
    local disk disk_names size mount avail used read_ops write_ops io_time_ms errs
    local -a df_warn=()
    local -a ino_warn=()

    echo "    Devices and filesystems:"

    if have lsblk; then
        disk_names="$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')"
    else
        disk_names=""
    fi

    if [[ -z "$disk_names" ]]; then
        if have lsblk; then
            echo "    No disks found"
        else
            echo "    lsblk is not available"
        fi
    else
        while IFS= read -r disk; do
            [[ -n "$disk" ]] || continue
            size="$(lsblk -b -d -n -o SIZE "/dev/$disk" 2>/dev/null || echo 0)"
            mount="$(lsblk -nr -o MOUNTPOINT "/dev/$disk" 2>/dev/null | grep -m1 . || true)"
            field "Disk" "/dev/$disk"
            field "Size" "$(bytes_to_human "$size")"
            if [[ -n "$mount" ]] && have df; then
                avail="$(df -kP "$mount" 2>/dev/null | awk 'NR == 2 {print $4}' || echo 0)"
                used="$(df -P "$mount" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}' || echo 0)"
                field "Mount point" "$mount"
                field "Free space" "$(kib_to_human "$avail") ($((100 - used))%)"
            else
                field "Mount point" "${mount:-none}"
            fi

            echo
            echo "    I/O activity:"
            read -r read_ops write_ops io_time_ms < <(disk_activity_delta "$disk")
            field "Read ops" "$read_ops"
            field "Write ops" "$write_ops"
            field "I/O time delta" "${io_time_ms} ms"

            echo
            echo "    Kernel messages:"
            errs="$(disk_kernel_error_matches "$disk")"
            field "Kernel log matches" "$errs"
            echo
        done <<< "$disk_names"
    fi

    echo
    echo "    Block devices:"
    if have lsblk; then
        lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | indent + 4
    else
        echo "    lsblk not found"
    fi

    echo
    echo "    Filesystems & partitions:"
    if have lsblk; then
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | indent + 4
    else
        echo "    lsblk not found"
    fi

    echo
    echo "    Disk usage warnings (>90%):"
    if have df; then
        mapfile -t df_warn < <(df -h | awk '$5+0>90{print "WARN:", $0}')
        if (( ${#df_warn[@]} )); then
            printf "%s\n" "${df_warn[@]}" | indent + 4
        else
            echo "    (none)"
        fi
    else
        echo "    df not found"
    fi

    echo
    echo "    Inode usage warnings (>90%):"
    if have df; then
        mapfile -t ino_warn < <(df -i | awk '$5+0>90{print "WARN: inode usage high:", $0}')
        if (( ${#ino_warn[@]} )); then
            printf "%s\n" "${ino_warn[@]}" | indent + 4
        else
            echo "    (none)"
        fi
    else
        echo "    df not found"
    fi
}

disk_read_stats() {
    local disk="${1:-}"
    [[ -z "$disk" ]] && return 1

    awk -v target="$disk" '
        $3 == target {
            print $4, $8, $13
            found=1
            exit
        }
        END {
            if (!found) exit 1
        }
    ' /proc/diskstats
}

disk_activity_delta() {
    local disk="${1:-}"
    local r1 w1 io1 r2 w2 io2

    [[ -z "$disk" ]] && {
        echo "0 0 0"
        return 0
    }

    read -r r1 w1 io1 < <(disk_read_stats "$disk" 2>/dev/null) || {
        echo "0 0 0"
        return 0
    }

    sleep 1

    read -r r2 w2 io2 < <(disk_read_stats "$disk" 2>/dev/null) || {
        echo "0 0 0"
        return 0
    }

    printf "%s %s %s\n" "$((r2 - r1))" "$((w2 - w1))" "$((io2 - io1))"
}

disk_kernel_error_matches() {
    local disk="${1:-}"
    local pattern count

    [[ -z "$disk" ]] && {
        echo "0"
        return 0
    }

    if ! dmesg >/dev/null 2>&1; then
        echo "N/A"
        return 0
    fi

    pattern="\\b${disk}\\b.*(I/O error|error|fail|critical|medium error|blk_update_request)"
    count="$(dmesg 2>/dev/null | grep -iEc "$pattern" || true)"
    echo "${count:-0}"
}

load_metrics() {
    local load1 load5 load15 cpu_cores per_cpu1 per_cpu5 per_cpu15 trend interpretation
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || {
        load1="0.00"; load5="0.00"; load15="0.00";
    }
    cpu_cores="$(nproc 2>/dev/null || echo 1)"
    [[ "$cpu_cores" -gt 0 ]] || cpu_cores=1
    per_cpu1="$(awk -v load="$load1" -v cpu="$cpu_cores" 'BEGIN { printf "%.2f", load / cpu }')"
    per_cpu5="$(awk -v load="$load5" -v cpu="$cpu_cores" 'BEGIN { printf "%.2f", load / cpu }')"
    per_cpu15="$(awk -v load="$load15" -v cpu="$cpu_cores" 'BEGIN { printf "%.2f", load / cpu }')"
    trend="$(awk -v l1="$load1" -v l5="$load5" -v l15="$load15" 'BEGIN {
        if (l1 > l5 && l5 >= l15) print "increasing";
        else if (l1 < l5 && l5 <= l15) print "decreasing";
        else print "stable/mixed";
    }')"
    interpretation="$(awk -v l1="$load1" -v cpu="$cpu_cores" 'BEGIN {
        if (l1 < cpu * 0.7) print "low demand relative to CPU count";
        else if (l1 < cpu) print "moderate demand relative to CPU count";
        else print "high demand relative to CPU count";
    }')"
    field "Load average (1m)" "$load1"
    field "Load average (5m)" "$load5"
    field "Load average (15m)" "$load15"
    field "CPU cores" "$cpu_cores"
    field "Load per CPU (1m)" "$per_cpu1"
    field "Load per CPU (5m)" "$per_cpu5"
    field "Load per CPU (15m)" "$per_cpu15"
    field "Trend" "$trend"
    field "Interpretation" "$interpretation"
    field "Note" "load includes runnable tasks and uninterruptible wait"
}

load_report() {
    echo -e "\n# Load"
    load_metrics
}

time_report() {
    echo -e "\n# Time"
    field "Current time" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

uptime_report() {
    local seconds
    echo -e "\n# Uptime"
    seconds="$(cut -d'.' -f1 /proc/uptime 2>/dev/null | cut -d' ' -f1 || echo 0)"
    field "Uptime" "$(format_uptime "$seconds")"
}

runtime_report() {
    local virt="unknown"
    local cgroup_fs="unknown"
    local cgroup_mode="unknown"

    echo -e "\n# Runtime"

    if have systemd-detect-virt; then
        virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
    elif [[ -f /.dockerenv ]]; then
        virt="docker"
    fi

    cgroup_fs="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
    if [[ -r /proc/self/cgroup ]]; then
        if grep -q '^0::' /proc/self/cgroup 2>/dev/null; then
            cgroup_mode="unified/v2"
        else
            cgroup_mode="legacy/v1 or hybrid"
        fi
    fi

    field "Virtualization" "$virt"
    field "Cgroup filesystem" "$cgroup_fs"
    field "Cgroup mode" "$cgroup_mode"
    field "Docker hint" "cgroupfs=cgroup2fs usually means cgroup v2"
}

network_report() {
    local path iface oper ip_addr ip6_addr rx tx
    echo -e "\n# Network"
    if ! have ip; then
        echo "    ip is not available"
        return 0
    fi
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        iface="$(basename "$path")"
        oper="$(cat "$path/operstate" 2>/dev/null || echo "unknown")"
        ip_addr="$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' || echo "-")"
        ip6_addr="$(ip -o -6 addr show dev "$iface" 2>/dev/null \
            | awk '{if (n++) printf ", "; printf "%s", $4}' || echo "-")"
        rx="$(cat "$path/statistics/rx_errors" 2>/dev/null || echo 0)"
        tx="$(cat "$path/statistics/tx_errors" 2>/dev/null || echo 0)"
        field "Interface" "$iface"
        field "Status" "$oper"
        field "IPv4" "${ip_addr:-"-"}"
        field "IPv6" "${ip6_addr:-"-"}"
        field "Errors" "$((rx + tx))"
        echo
    done
}

network_snapshot() {
    local primary_iface ipv4_addr ipv6_addr gateway ipv6_gateway ipv4_routes
    local dns_resolver path iface oper ip_addr ip6_addr rx tx
    local ipv6_routes

    echo -e "\n# Network"
    echo "    Network summary:"
    primary_iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
    ipv4_addr=""
    ipv6_addr=""
    gateway="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    ipv6_gateway="$(ip -6 route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [[ -n "$primary_iface" ]]; then
        ipv4_addr="$(ip -4 addr show "$primary_iface" 2>/dev/null \
            | awk '/inet / {print $2; exit}')"
        ipv6_addr="$(ip -6 addr show "$primary_iface" 2>/dev/null \
            | awk '$1 == "inet6" {print $2; exit}')"
    fi
    [[ -n "$primary_iface" ]] || primary_iface="-"
    [[ -n "$ipv4_addr" ]] || ipv4_addr="-"
    [[ -n "$gateway" ]] || gateway="-"
    [[ -n "$ipv6_addr" ]] || ipv6_addr="-"
    [[ -n "$ipv6_gateway" ]] || ipv6_gateway="-"
    printf "        Primary interface:       %s\n" "$primary_iface"
    printf "        IPv4 address:             %s\n" "$ipv4_addr"
    printf "        IPv4 default gateway:     %s\n" "$gateway"
    printf "        IPv6 addresses:           %s\n" "$ipv6_addr"
    printf "        IPv6 default gateway:     %s\n" "$ipv6_gateway"

    echo
    echo "    Interfaces:"
    printf "        %-18s %-9s %-18s %-45s %s\n" \
        "INTERFACE" "STATUS" "IPv4" "IPv6" "ERRORS"
    for path in /sys/class/net/*; do
        [[ -e "$path" ]] || continue
        iface="$(basename "$path")"
        oper="$(cat "$path/operstate" 2>/dev/null || echo unknown)"
        ip_addr="$(ip -o -4 addr show dev "$iface" 2>/dev/null \
            | awk '{if (n++) printf ", "; printf "%s", $4}')"
        ip6_addr="$(ip -o -6 addr show dev "$iface" 2>/dev/null \
            | awk '{if (n++) printf ", "; printf "%s", $4}')"
        rx="$(cat "$path/statistics/rx_errors" 2>/dev/null || echo 0)"
        tx="$(cat "$path/statistics/tx_errors" 2>/dev/null || echo 0)"
        [[ -n "$ip_addr" ]] || ip_addr="-"
        [[ -n "$ip6_addr" ]] || ip6_addr="-"
        printf "        %-18s %-9s %-18s %-45s %s\n" \
            "$iface" "$oper" "$ip_addr" "$ip6_addr" "$((rx + tx))"
    done

    echo
    echo "    DNS:"
    dns_resolver="none detected"
    if have systemctl; then
        for SVC in systemd-resolved unbound bind9 dnsmasq cloudflared adguardhome; do
            if systemctl is-active --quiet "$SVC"; then
                case "$SVC" in
                    systemd-resolved) dns_resolver="systemd-resolved" ;;
                    unbound)          dns_resolver="Unbound" ;;
                    bind9)            dns_resolver="BIND9" ;;
                    dnsmasq)          dns_resolver="dnsmasq" ;;
                    cloudflared)      dns_resolver="cloudflared (DoH proxy)" ;;
                    adguardhome)      dns_resolver="AdGuard Home" ;;
                esac
                break
            fi
        done
    fi
    printf "        Resolver service:         %s\n" "$dns_resolver"
    echo "        Nameservers:"
    if ! awk '/^nameserver/ {printf "            %s\n", $2; found=1} END {exit !found}' \
        /etc/resolv.conf; then
        echo "            (none)"
    fi

    echo
    echo "    IPv4 routes:"
    ipv4_routes="$(ip route 2>/dev/null || true)"
    if [[ -n "$ipv4_routes" ]]; then
        printf '%s\n' "$ipv4_routes" | sed 's/^/        /'
    else
        echo "        (none)"
    fi
    echo
    echo "    IPv6 routes:"
    ipv6_routes="$(ip -6 route 2>/dev/null || true)"
    if [[ -n "$ipv6_routes" ]]; then
        printf '%s\n' "$ipv6_routes" | sed 's/^/        /'
    else
        echo "        (none)"
    fi

    echo
    echo "    Listening TCP/UDP ports:"
    ports_metrics | sed 's/^/    /'

    echo -e "\n# IPv4 NAT table & rules"
    {
        if command -v iptables-save &>/dev/null; then
            iptables-save -t nat
        elif command -v iptables &>/dev/null; then
            for CHAIN in PREROUTING INPUT OUTPUT POSTROUTING; do
                echo "--- $CHAIN ---"
                iptables -t nat -L "$CHAIN" -n -v --line-numbers
            done
        else
            echo "(none)"
        fi
    } | indent + 4

    echo -e "\n# IPv6 NAT table & rules"
    {
        if command -v ip6tables-save &>/dev/null; then
            ip6tables-save -t nat
        elif command -v ip6tables &>/dev/null; then
            for CHAIN in PREROUTING INPUT OUTPUT POSTROUTING; do
                echo "--- $CHAIN ---"
                ip6tables -t nat -L "$CHAIN" -n -v --line-numbers
            done
        else
            echo "(none)"
        fi
    } | indent + 4
}

ports_metrics() {
    if have ss; then
        {
            printf "%-6s %-8s %-6s %-6s %-30s %-22s %s\n" \
                "Netid" "State" "Recv-Q" "Send-Q" "Local Address:Port" "Peer Address:Port" "Process"

            ss -tuplnH 2>/dev/null | awk '
                {
                    process = ""
                    if (NF >= 7) {
                        process = $7
                        for (i = 8; i <= NF; i++) {
                            process = process " " $i
    }
}

disk_report() {
    echo -e "\n# Disk"
    disk_metrics
}

                    printf "%-6s %-8s %-6s %-6s %-30s %-22s %s\n",
                        $1, $2, $3, $4, $5, $6, process
                }
            '
        } | indent + 4 || echo "    Cannot read listening ports"
    else
        echo "    ss is not available"
    fi
}

ports_report() {
    echo -e "\n# Listening TCP/UDP ports"
    ports_metrics
}

users_report() {
    echo -e "\n# Users"
    {
        awk -F: '
        $3 < 1000 && $3 != 0 {
            system_users[++system_count] = $0
        }
        $3 == 0 {
            root_users[++root_count] = $0
        }
        $3 >= 1000 && $1 != "nobody" {
            regular_users[++regular_count] = $0
        }
        END {
            print "";
            print "System users:";
            if (system_count == 0) print "none";
            for (i = 1; i <= system_count; i++) {
                split(system_users[i], f, ":");
                printf "%-17s uid=%-5s home=%-28s shell=%s\n", f[1], f[3], f[6], f[7]
            }

            print "";
            print "Root users:";
            if (root_count == 0) print "none";
            for (i = 1; i <= root_count; i++) {
                split(root_users[i], f, ":");
                printf "%-17s uid=%-5s home=%-28s shell=%s\n", f[1], f[3], f[6], f[7]
            }

            print "";
            print "Regular users:";
            if (regular_count == 0) print "none";
            for (i = 1; i <= regular_count; i++) {
                split(regular_users[i], f, ":");
                printf "%-17s uid=%-5s home=%-28s shell=%s\n", f[1], f[3], f[6], f[7]
            }
        }
        ' /etc/passwd

        echo
        echo "Group-based sudo users:"
        if have getent; then
            local sudo_members wheel_members
            sudo_members="$(getent group sudo 2>/dev/null | awk -F: '{print $4}')"
            wheel_members="$(getent group wheel 2>/dev/null | awk -F: '{print $4}')"
            if [[ -n "$sudo_members" ]]; then
                echo "from sudo: $sudo_members"
            fi
            if [[ -n "$wheel_members" ]]; then
                echo "from wheel: $wheel_members"
            fi
            if [[ -z "$sudo_members" && -z "$wheel_members" ]]; then
                echo "none"
            fi
        else
            echo "getent not found"
        fi
    } | indent + 4
}

mask_secrets() {
    sed -E 's/^([^=]*(TOKEN|SECRET|PASSWORD|PASS|KEY|CREDENTIAL|PRIVATE|API_KEY|ACCESS_KEY)[^=]*)=.*/\1=***MASKED***/I'
}

docker_inspect_field() {
    local target="$1"
    local template="$2"
    docker inspect -f "$template" "$target" 2>/dev/null || true
}

docker_report() {
    echo -e "\n# Docker"
    if ! have docker; then
        echo "    Docker is not installed or not available"
        return 0
    fi

    echo "    docker version:"
    docker version --format '    Client={{.Client.Version}} Server={{.Server.Version}}' 2>/dev/null \
        || docker version 2>/dev/null | indent + 4 \
        || echo "    Cannot read docker version"

    echo
    echo "    containers:"
    docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | indent + 4 \
        || echo "    Cannot list containers"

    echo
    echo "    networks:"
    docker network ls 2>/dev/null | indent + 4 || echo "    Cannot list networks"

    echo
    echo "    volumes:"
    docker volume ls 2>/dev/null | indent + 4 || echo "    Cannot list volumes"
}

docker_snapshot_report() {
    local ids id name image state restart health project ports

    echo -e "\n# Docker"
    if ! have docker; then
        echo "    Docker is not installed or not available"
        return 0
    fi

    echo
    echo "    docker version:"
    docker version 2>/dev/null | indent + 4 || echo "    Cannot read docker version"

    echo
    echo "    docker info:"
    docker info 2>/dev/null | indent + 4 || echo "    Cannot read docker info"

    echo
    echo "    containers:"
    docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | indent + 4 \
        || echo "    Cannot list containers"

    echo
    echo "    networks:"
    docker network ls 2>/dev/null | indent + 4 || echo "    Cannot list networks"

    echo
    echo "    volumes:"
    docker volume ls 2>/dev/null | indent + 4 || echo "    Cannot list volumes"

    echo
    echo "    all containers summary:"
    printf "    %-24s %-28s %-18s %-8s %-12s %-20s %s\n" \
        "NAME" "IMAGE" "STATE" "RESTART" "HEALTH" "COMPOSE" "PORTS"

    ids="$(docker ps -aq 2>/dev/null || true)"
    if [[ -z "$ids" ]]; then
        echo "    No containers or cannot list containers"
        return 0
    fi

    printf "%s\n" "$ids" | while read -r id; do
        [[ -n "$id" ]] || continue
        name="$(docker_inspect_field "$id" '{{.Name}}' | sed 's#^/##')"
        image="$(docker_inspect_field "$id" '{{.Config.Image}}')"
        state="$(docker_inspect_field "$id" '{{.State.Status}}')"
        restart="$(docker_inspect_field "$id" '{{.RestartCount}}')"
        health="$(docker_inspect_field "$id" '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
        project="$(docker_inspect_field "$id" '{{index .Config.Labels "com.docker.compose.project"}}')"
        ports="$(docker port "$id" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
        [[ -n "$ports" ]] || ports="-"
        [[ -n "$project" ]] || project="-"

        printf "    %-24.24s %-28.28s %-18.18s %-8.8s %-12.12s %-20.20s %s\n" \
            "$name" "$image" "$state" "$restart" "$health" "$project" "$ports"
    done
}

docker_container_report() {
    local container="$1"
    local image_id
    local compose_project

    echo -e "\n# Docker container: $container"
    if ! have docker; then
        echo "    Docker is not installed or not available"
        return 0
    fi
    if ! docker inspect "$container" >/dev/null 2>&1; then
        echo "    Container not found: $container"
        return 1
    fi

    image_id="$(docker_inspect_field "$container" '{{.Image}}')"
    compose_project="$(docker_inspect_field "$container" '{{index .Config.Labels "com.docker.compose.project"}}')"

    echo
    echo "    state:"
    docker inspect -f '
    Name:          {{.Name}}
    Image:         {{.Config.Image}}
    Status:        {{.State.Status}}
    Running:       {{.State.Running}}
    StartedAt:     {{.State.StartedAt}}
    ExitCode:      {{.State.ExitCode}}
    OOMKilled:     {{.State.OOMKilled}}
    RestartCount:  {{.RestartCount}}
    Health:        {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}
    ' "$container" 2>/dev/null

    echo
    echo "    command:"
    docker inspect -f '
    Entrypoint: {{json .Config.Entrypoint}}
    Cmd:        {{json .Config.Cmd}}
    WorkingDir: {{.Config.WorkingDir}}
    User:       {{.Config.User}}
    ' "$container" 2>/dev/null

    echo
    echo "    security:"
    docker inspect -f '
    Privileged:     {{.HostConfig.Privileged}}
    ReadonlyRootfs: {{.HostConfig.ReadonlyRootfs}}
    PidMode:        {{.HostConfig.PidMode}}
    IpcMode:        {{.HostConfig.IpcMode}}
    CgroupnsMode:   {{.HostConfig.CgroupnsMode}}
    CapAdd:         {{json .HostConfig.CapAdd}}
    CapDrop:        {{json .HostConfig.CapDrop}}
    SecurityOpt:    {{json .HostConfig.SecurityOpt}}
    ' "$container" 2>/dev/null

    echo
    echo "    resources:"
    docker inspect -f '
    Memory:     {{.HostConfig.Memory}}
    MemorySwap: {{.HostConfig.MemorySwap}}
    NanoCpus:   {{.HostConfig.NanoCpus}}
    PidsLimit:  {{.HostConfig.PidsLimit}}
    ' "$container" 2>/dev/null

    echo
    echo "    compose:"
    field "Project" "${compose_project:-"-"}"
    field "Service" "$(docker_inspect_field "$container" '{{index .Config.Labels "com.docker.compose.service"}}')"

    echo
    echo "    networks:"
    docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{printf "    %-18s IP=%-16s Gateway=%-16s Mac=%s\n" $name $net.IPAddress $net.Gateway $net.MacAddress}}{{end}}' "$container" 2>/dev/null

    echo
    echo "    ports:"
    docker port "$container" 2>/dev/null | indent + 4 || echo "    No published ports"

    echo
    echo "    mounts:"
    docker inspect -f '{{range .Mounts}}{{printf "    Type=%s Source=%s Destination=%s RW=%v\n" .Type .Source .Destination .RW}}{{end}}' "$container" 2>/dev/null

    echo
    echo "    environment (secrets masked):"
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null \
        | mask_secrets \
        | indent + 4

    echo
    echo "    process list:"
    docker top "$container" 2>/dev/null | indent + 4 || echo "    Cannot read process list"

    echo
    echo "    resource usage:"
    docker stats --no-stream "$container" 2>/dev/null | indent + 4 || echo "    Cannot read stats"

    echo
    echo "    filesystem diff:"
    docker diff "$container" 2>/dev/null | indent + 4 || echo "    No diff or cannot read diff"

    echo
    echo "    rootfs layers:"
    docker inspect -f '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_id" 2>/dev/null \
        | sed '/^$/d' \
        | nl -w1 -s'  ' \
        | indent + 4 \
        || echo "    Cannot read image layers"
}

run_reports() {
    local ran=0

    if (( ALL_REPORT )); then
        snapshot
        return 0
    fi

    if (( CPU_REPORT )); then cpu_report; ran=1; fi
    if (( MEMORY_REPORT )); then memory_report; ran=1; fi
    if (( DISK_REPORT )); then disk_report; ran=1; fi
    if (( LOAD_REPORT )); then load_report; ran=1; fi
    if (( UPTIME_REPORT )); then uptime_report; ran=1; fi
    if (( RUNTIME_REPORT )); then runtime_report; ran=1; fi
    if (( NETWORK_REPORT )); then network_report; ran=1; fi
    if (( PORTS_REPORT )); then ports_report; ran=1; fi
    if (( USERS_REPORT )); then users_report; ran=1; fi
    if (( DOCKER_REPORT )); then docker_report; ran=1; fi
    if [[ -n "$DOCKER_CONTAINER" ]]; then docker_container_report "$DOCKER_CONTAINER"; ran=1; fi

    [[ "$ran" -eq 1 ]]
}

# parse options
# parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Hidden files, only directories, max depth
        -a) SHOW_HIDDEN=1; shift;;
        -d) ONLY_DIRS=1; shift;;
        -L)
            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: -L requires a numeric argument." >&2; usage
            fi
            MAX_DEPTH=$2; shift 2;;

        # Include/exclude filters
        -P)
            if [[ -z "$2" ]]; then
                echo "Error: -P requires a pattern argument." >&2; usage
            fi
            INCLUDE+=("$2"); shift 2;;
        -I)
            if [[ -z "$2" ]]; then
                echo "Error: -I requires a pattern argument." >&2; usage
            fi
            EXCLUDE+=("$2"); shift 2;;

        # Output formatting options
        -f) FULL_PATH=1; shift;;
        -F) CLASSIFY=1; shift;;
        -p) SHOW_PERM=1; shift;;
        -u) SHOW_USER=1; shift;;
        -g) SHOW_GROUP=1; shift;;
        --dirsfirst) DIRS_FIRST=1; shift;;
        -T|--time) SHOW_TIME=1; shift;;

        # Sorting options (by size or mtime)
        --sort-size) SORT_SIZE=1; shift;;
        --sort-mtime) SORT_MTIME=1; shift;;

        # Special modes and reports
        --package) FORCE_PACKAGE=1; shift;;
        -t|--top)
            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: -t/--top requires a numeric argument." >&2; usage
            fi
            TOP_N=$2; shift 2;;
        -r|--dfreport) DFREPORT=1; shift;;
        -s|--snapshot) SNAPSHOT=1; shift;;
        --all) ALL_REPORT=1; shift;;
        --cpu) CPU_REPORT=1; shift;;
        --memory) MEMORY_REPORT=1; shift;;
        --disk) DISK_REPORT=1; shift;;
        --load) LOAD_REPORT=1; shift;;
        --uptime) UPTIME_REPORT=1; shift;;
        --runtime) RUNTIME_REPORT=1; shift;;
        --network) NETWORK_REPORT=1; shift;;
        --ports) PORTS_REPORT=1; shift;;
        --users) USERS_REPORT=1; shift;;
        --docker) DOCKER_REPORT=1; shift;;
        --docker-container)
            if [[ -z "$2" ]]; then
                echo "Error: --docker-container requires a container name or ID." >&2; usage
            fi
            DOCKER_CONTAINER="$2"; shift 2;;
        -z|--size) SHOW_SIZE=1; shift;;
        -h|--help) usage;;

        # End of options or positional argument
        --) shift; break;;
        *) TARGET="$1"; shift; break;;
    esac
done

# snapshot mode
if (( SNAPSHOT )); then
    snapshot; exit 0
fi

if run_reports; then
    exit 0
fi

# determine target mode
TARGET="${TARGET:-$PWD}"

# --package: try to find a package even by binary and alternatives
resolve_package() {
    local NAME="$1"
    # 1. Checking by dpkg/pacman directly
    if command -v dpkg-query &>/dev/null && dpkg-query -W -f='${Status}' "$NAME" 2>/dev/null | grep -q "install ok installed"; then
        PACKAGE_MODE=1
        mapfile -t PKGFILES < <(dpkg-query -L "$NAME")
        ROOT="/"
        return 0
    elif command -v pacman &>/dev/null && pacman -Qi "$NAME" &>/dev/null; then
        PACKAGE_MODE=1
        mapfile -t PKGFILES < <(pacman -Ql "$NAME" | awk '{print $2}')
        ROOT="/"
        return 0
    fi

    # 2. If no package is found - look for the binary
    if command -v "$NAME" &>/dev/null; then
        local BIN_PATH
        BIN_PATH=$(command -v "$NAME")
        # 2a. Attempting to identify a packet from a binary
        if command -v dpkg-query &>/dev/null; then
            PKG_REAL=$(dpkg-query -S "$BIN_PATH" 2>/dev/null | head -n1 | cut -d: -f1)
            if [ -n "$PKG_REAL" ]; then
                PACKAGE_MODE=1
                mapfile -t PKGFILES < <(dpkg-query -L "$PKG_REAL")
                ROOT="/"
                return 0
            fi
        elif command -v pacman &>/dev/null; then
            PKG_REAL=$(pacman -Qo "$BIN_PATH" 2>/dev/null | awk '{print $5}')
            if [ -n "$PKG_REAL" ]; then
                PACKAGE_MODE=1
                mapfile -t PKGFILES < <(pacman -Ql "$PKG_REAL" | awk '{print $2}')
                ROOT="/"
                return 0
            fi
        fi
        # 2b. If this is an alternative - look for a realistic goal
        if command -v update-alternatives &>/dev/null; then
            ALT_TARGET=$(update-alternatives --display "$NAME" 2>/dev/null | awk '/link currently points to/ {print $5}')
            [ -z "$ALT_TARGET" ] && ALT_TARGET=$(update-alternatives --display "$NAME" 2>/dev/null | awk '/best version is/ {print $5}')
            if [ -n "$ALT_TARGET" ] && [ -e "$ALT_TARGET" ]; then
                # Trying to find a package for the real purpose of the alternatives
                if command -v dpkg-query &>/dev/null; then
                    PKG_REAL=$(dpkg-query -S "$ALT_TARGET" 2>/dev/null | head -n1 | cut -d: -f1)
                    if [ -n "$PKG_REAL" ]; then
                        PACKAGE_MODE=1
                        mapfile -t PKGFILES < <(dpkg-query -L "$PKG_REAL")
                        ROOT="/"
                        return 0
                    fi
                elif command -v pacman &>/dev/null; then
                    PKG_REAL=$(pacman -Qo "$ALT_TARGET" 2>/dev/null | awk '{print $5}')
                    if [ -n "$PKG_REAL" ]; then
                        PACKAGE_MODE=1
                        mapfile -t PKGFILES < <(pacman -Ql "$PKG_REAL" | awk '{print $2}')
                        ROOT="/"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    # If you can't find it, it's an error
    return 1
}

if (( FORCE_PACKAGE )); then
    if ! resolve_package "$TARGET"; then
        echo "Error: package or binary '$TARGET' is not installed or not resolvable" >&2
        exit 1
    fi
elif command -v "$TARGET" &>/dev/null; then
    FILE_MODE=1
    FILE_PATH=$(command -v "$TARGET")
    ROOT=$(dirname "$FILE_PATH")
elif [[ -f "$TARGET" ]]; then
    FILE_MODE=1
    FILE_PATH=$(realpath "$TARGET")
    ROOT=$(dirname "$FILE_PATH")
elif [[ -d "$TARGET" ]]; then
    ROOT="$TARGET"
elif resolve_package "$TARGET"; then
    # auto-detect for pure package call if nothing else
    :
else
    echo "Error: '$TARGET' is not file, dir, executable, or package" >&2
    exit 1
fi

# package file setup
if (( PACKAGE_MODE )); then
    declare -A PKGSET=()
    for F in "${PKGFILES[@]}"; do
        PKGSET["$F"]=1
    done
fi

# main
if (( TOP_N==0 )); then
    COUNT_DIRS=0; COUNT_FILES=0
    if (( FULL_PATH )) && (( ${#INCLUDE[@]} )); then
        pattern=""
        for rx in "${INCLUDE[@]}"; do [[ -n "$pattern" ]] && pattern="$pattern|"; pattern="$pattern$rx"; done
        [[ -z "$pattern" ]] && pattern="."
        find "$ROOT" -type f -regextype posix-extended -regex ".*($pattern)" 2>/dev/null | sort -V
        exit 0
    fi
    if (( ${#INCLUDE[@]} )); then
        print_min_tree "${ROOT:-$TARGET}" "$MAX_DEPTH"
    else
        printf '%b%s%b\n' "$DIR_COL" "${ROOT:-$TARGET}" "$RESET"
        print_tree "${ROOT:-$TARGET}" 1 ""
        echo; printf '%d directories, %d files\n' "$COUNT_DIRS" "$COUNT_FILES"
    fi
fi

if (( TOP_N>0 )); then
    echo; echo "Top $TOP_N largest files in ${COMMON_PATHS[*]} (readable):"
    du -x -b "${COMMON_PATHS[@]}" 2>/dev/null | sort -rn -k1 | head -n "$TOP_N" | awk '{cmd="numfmt --to=iec "$1; cmd|getline h; close(cmd); printf "%8s  %s\n",h,$2}'
fi

if (( DFREPORT )); then
    echo; echo "Disk space for $ROOT:"; df -h "$ROOT"
    echo; echo "Inodes for $ROOT:"; df -i "$ROOT"
fi
