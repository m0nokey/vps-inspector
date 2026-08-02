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

device_model() {
    local disk="$1"
    local device="/dev/$disk"
    local model vendor virt

    model="$(lsblk -d -n -o MODEL "$device" 2>/dev/null \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
    if [[ -z "$model" ]] && have udevadm; then
        vendor="$(udevadm info --query=property --name="$device" 2>/dev/null \
            | sed -n 's/^ID_VENDOR=//p' | head -n 1 \
            | sed 's/_/ /g')"
        model="$(udevadm info --query=property --name="$device" 2>/dev/null \
            | sed -n 's/^ID_MODEL=//p' | head -n 1 \
            | sed 's/_/ /g')"
        if [[ -z "$model" ]]; then
            model="$(udevadm info --query=property --name="$device" 2>/dev/null \
                | sed -n 's/^ID_MODEL_FROM_DATABASE=//p' | head -n 1 \
                | sed 's/_/ /g')"
        fi
        if [[ -n "$vendor" && -n "$model" ]]; then
            model="$vendor $model"
        fi
    fi
    if [[ -z "$model" ]] && [[ -r "/sys/block/$disk/device/model" ]]; then
        model="$(<"/sys/block/$disk/device/model")"
        model="$(printf '%s' "$model" \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    fi
    if [[ -z "$model" ]] && have systemd-detect-virt; then
        virt="$(systemd-detect-virt --vm 2>/dev/null || true)"
        case "$virt" in
            kvm|qemu)
                model="QEMU/KVM virtual disk"
                ;;
        esac
    fi

    if [[ -z "$model" ]]; then
        model="not exposed"
    fi
    printf '%s\n' "$model"
}

storage_kv() {
    printf "        %-24s %s\n" "$1:" "$2"
}

storage_devices_table() {
    local row name size type fstype mount vendor model free_space
    local max_name=4 max_size=4 max_type=4 max_fstype=6 max_mount=11 max_free=10 max_model=5
    local i
    local -a names=() sizes=() types=() fstypes=() mounts=() frees=() models=()

    while IFS= read -r row; do
        name="$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<< "$row")"
        size="$(sed -n 's/.* SIZE="\([^"]*\)".*/\1/p' <<< "$row")"
        type="$(sed -n 's/.* TYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        fstype="$(sed -n 's/.* FSTYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        mount="$(sed -n 's/.* MOUNTPOINT="\([^"]*\)".*/\1/p' <<< "$row")"
        vendor="$(sed -n 's/.* VENDOR="\([^"]*\)".*/\1/p' <<< "$row")"
        model="$(sed -n 's/.* MODEL="\([^"]*\)".*/\1/p' <<< "$row")"
        [[ -n "$name" ]] || continue

        if [[ "$type" == disk ]]; then
            if [[ -n "$vendor" && -n "$model" ]]; then
                model="$vendor $model"
            elif [[ -z "$model" ]]; then
                model="$(device_model "$name")"
            fi
        fi
        free_space="-"
        if [[ -n "$mount" ]] && have df; then
            free_space="$(df -kP "$mount" 2>/dev/null \
                | awk 'NR == 2 {gsub("%", "", $5); printf "%.2fG", $4 / 1024 / 1024}')"
            [[ -n "$free_space" ]] || free_space="-"
        fi

        size="${size:--}"; type="${type:--}"; fstype="${fstype:--}"
        mount="${mount:--}"; model="${model:--}"
        names+=("$name"); sizes+=("$size"); types+=("$type")
        fstypes+=("$fstype"); mounts+=("$mount"); frees+=("$free_space"); models+=("$model")
        ((${#name} > max_name)) && max_name=${#name}
        ((${#size} > max_size)) && max_size=${#size}
        ((${#type} > max_type)) && max_type=${#type}
        ((${#fstype} > max_fstype)) && max_fstype=${#fstype}
        ((${#mount} > max_mount)) && max_mount=${#mount}
        ((${#free_space} > max_free)) && max_free=${#free_space}
        ((${#model} > max_model)) && max_model=${#model}
    done < <(lsblk -P -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,VENDOR,MODEL 2>/dev/null)

    printf "        %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n" \
        "$max_name" NAME "$max_size" SIZE "$max_type" TYPE "$max_fstype" FSTYPE \
        "$max_mount" MOUNTPOINT "$max_free" "FREE SPACE" MODEL
    for ((i = 0; i < ${#names[@]}; i++)); do
        printf "        %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n" \
            "$max_name" "${names[i]}" "$max_size" "${sizes[i]}" \
            "$max_type" "${types[i]}" "$max_fstype" "${fstypes[i]}" \
            "$max_mount" "${mounts[i]}" "$max_free" "${frees[i]}" "${models[i]}"
    done
    ((${#names[@]} > 0)) || echo "        none"
}

disk_io_activity_table() {
    local disk disk_names="$1" read_ops write_ops io_time_ms last_index
    local max_device=6 max_read=8 max_write=9 max_io=14 i
    local -a devices=() reads=() writes=() io_times=()

    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        read -r read_ops write_ops io_time_ms < <(disk_activity_delta "$disk")
        devices+=("/dev/$disk"); reads+=("$read_ops"); writes+=("$write_ops"); io_times+=("$io_time_ms ms")
        last_index=$(( ${#devices[@]} - 1 ))
        ((${#devices[last_index]} > max_device)) && max_device=${#devices[last_index]}
        ((${#read_ops} > max_read)) && max_read=${#read_ops}
        ((${#write_ops} > max_write)) && max_write=${#write_ops}
        ((${#io_times[last_index]} > max_io)) && max_io=${#io_times[last_index]}
    done <<< "$disk_names"

    echo "    I/O activity:"
    printf "        %-*s  %-*s  %-*s  %-*s\n" \
        "$max_device" DEVICE "$max_read" "READ OPS" "$max_write" "WRITE OPS" \
        "$max_io" "I/O TIME DELTA"
    for ((i = 0; i < ${#devices[@]}; i++)); do
        printf "        %-*s  %-*s  %-*s  %-*s\n" \
            "$max_device" "${devices[i]}" "$max_read" "${reads[i]}" \
            "$max_write" "${writes[i]}" "$max_io" "${io_times[i]}"
    done
    ((${#devices[@]} > 0)) || echo "        none"
}

format_scaled_value() {
    local value="${1:-0}"
    local divisor="$2"
    local unit="$3"
    local scaled

    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    scaled="$(( (value * 100 + divisor / 2) / divisor ))"
    printf "%d.%02d %s" "$((scaled / 100))" "$((scaled % 100))" "$unit"
}

kib_to_human() {
    local kib="${1:-0}"

    [[ "$kib" =~ ^[0-9]+$ ]] || kib=0
    if (( kib >= 1024 * 1024 )); then
        format_scaled_value "$kib" $((1024 * 1024)) "GiB"
    elif (( kib >= 1024 )); then
        format_scaled_value "$kib" 1024 "MiB"
    else
        printf "%d KiB" "$kib"
    fi
}

bytes_to_human() {
    local bytes="${1:-0}"

    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes >= 1024 * 1024 * 1024 * 1024 )); then
        format_scaled_value "$bytes" $((1024 * 1024 * 1024 * 1024)) "TiB"
    elif (( bytes >= 1024 * 1024 * 1024 )); then
        format_scaled_value "$bytes" $((1024 * 1024 * 1024)) "GiB"
    elif (( bytes >= 1024 * 1024 )); then
        format_scaled_value "$bytes" $((1024 * 1024)) "MiB"
    elif (( bytes >= 1024 )); then
        format_scaled_value "$bytes" 1024 "KiB"
    else
        printf "%d B" "$bytes"
    fi
}

format_uptime() {
    local seconds="${1:-0}"
    printf "%d days, %d hours, %d minutes" \
        "$((seconds / 86400))" \
        "$(((seconds % 86400) / 3600))" \
        "$(((seconds % 3600) / 60))"
}

cpu_field() {
    printf "    %-24s %s\n" "$1:" "$2"
}

read_cpu_counters() {
    local cpu user nice system idle iowait irq softirq steal

    read -r cpu user nice system idle iowait irq softirq steal < /proc/stat || return 1
    [[ "$cpu" == "cpu" ]] || return 1
    printf "%s %s %s %s %s %s %s %s\n" \
        "$user" "$nice" "$system" "$idle" "$iowait" "$irq" "$softirq" "$steal"
}

cpu_metrics() {
    local before after
    local user nice system idle iowait irq softirq steal
    local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
    local user_pct nice_pct system_pct idle_pct iowait_pct irq_pct
    local softirq_pct steal_pct
    if have nproc; then
        cpu_field "CPU cores" "$(nproc)"
    else
        cpu_field "CPU cores" "(unknown)"
    fi

    if [[ -r /proc/stat ]]; then
        read -r user nice system idle iowait irq softirq steal < <(
            read_cpu_counters
        )
        sleep 1
        read -r user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 < <(
            read_cpu_counters
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
        cpu_field "User time" "${user_pct:-0.0}%"
        cpu_field "System time" "${system_pct:-0.0}%"
        cpu_field "Nice process time" "${nice_pct:-0.0}%"
        cpu_field "Idle time" "${idle_pct:-0.0}%"
        cpu_field "I/O wait time" "${iowait_pct:-0.0}%"
        cpu_field "Hardware interrupt time" "${irq_pct:-0.0}%"
        cpu_field "Software interrupt time" "${softirq_pct:-0.0}%"
        cpu_field "Steal time" "${steal_pct:-0.0}%"
    else
        cpu_field "CPU timing" " /proc/stat unavailable"
    fi
}

cpu_report() {
    echo -e "\n# CPU"
    cpu_metrics
}

meminfo_value() {
    local wanted_key="$1"
    local key value unit

    while read -r key value unit; do
        if [[ "$key" == "${wanted_key}:" ]]; then
            printf "%s\n" "${value:-0}"
            return 0
        fi
    done < /proc/meminfo

    printf "0\n"
}

swap_metrics() {
    local source type size_kib used_kib priority size_bytes used_bytes index=0

    if [[ -r /proc/swaps ]]; then
        while read -r source type size_kib used_kib priority; do
            [[ "$source" == "Filename" ]] && continue
            [[ -n "$source" ]] || continue
            index=$((index + 1))
            size_bytes="$((size_kib * 1024))"
            used_bytes="$((used_kib * 1024))"
            field "Swap source ${index}" "$source"
            field "Swap type ${index}" "$type"
            field "Swap size ${index}" "$(bytes_to_human "$size_bytes")"
            field "Swap used ${index}" "$(bytes_to_human "$used_bytes")"
            field "Swap priority ${index}" "$priority"
        done < /proc/swaps
    fi

    if (( index == 0 )); then
        field "Swap status" "disabled"
        field "Swap source" "none"
        field "Swap type" "none"
    else
        field "Swap status" "enabled (${index} source$( (( index == 1 )) && printf '' || printf 's' ))"
    fi
}

memory_metrics() {
    local total free buffers cached avail used swap_total swap_free swap_used
    total="$(meminfo_value MemTotal)"
    free="$(meminfo_value MemFree)"
    buffers="$(meminfo_value Buffers)"
    cached="$(meminfo_value Cached)"
    avail="$(meminfo_value MemAvailable)"
    used="$((total - avail))"
    swap_total="$(meminfo_value SwapTotal)"
    swap_free="$(meminfo_value SwapFree)"
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
    swap_metrics
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
    local disk_names disk errs kernel_matches

    echo "    Devices and filesystems:"
    if ! have lsblk; then
        echo "        unavailable (lsblk not found)"
    else
        storage_devices_table
    fi

    lvm_metrics

    storage_health_report

    disk_names="$(lsblk -d -n -o NAME,TYPE 2>/dev/null \
        | awk '$2 == "disk" {print $1}')"
    disk_io_activity_table "$disk_names"

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
    local disk disk_names size mount model avail used errs
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
            model="$(device_model "$disk")"
            field "Disk" "/dev/$disk"
            field "Size" "$(bytes_to_human "$size")"
            field "Disk model" "$model"
            if [[ -n "$mount" ]] && have df; then
                avail="$(df -kP "$mount" 2>/dev/null | awk 'NR == 2 {print $4}' || echo 0)"
                used="$(df -P "$mount" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}' || echo 0)"
                field "Mount point" "$mount"
                field "Free space" "$(kib_to_human "$avail") ($((100 - used))%)"
            else
                field "Mount point" "${mount:-none}"
            fi

            echo
            echo "    Kernel messages:"
            errs="$(disk_kernel_error_matches "$disk")"
            field "Kernel log matches" "$errs"
            echo
        done <<< "$disk_names"
    fi

    if [[ -n "$disk_names" ]]; then
        disk_io_activity_table "$disk_names"
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

    lvm_metrics

    storage_health_report

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

lvm_metrics() {
    local row path type size fstype mount found=0
    local lv_path vg_name lv_size

    echo
    echo "    LVM:"
    if ! have lsblk; then
        field "LVM status" "unknown (lsblk not found)"
        return 0
    fi

    while IFS= read -r row; do
        path="$(sed -n 's/.*PATH="\([^"]*\)".*/\1/p' <<< "$row")"
        type="$(sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        size="$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<< "$row")"
        fstype="$(sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p' <<< "$row")"
        mount="$(sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p' <<< "$row")"
        [[ "$type" == "lvm" ]] || continue
        found=$((found + 1))
        [[ -n "$fstype" ]] || fstype=none
        [[ -n "$mount" ]] || mount=none
        field "Logical volume $found" "$path"
        field "LVM size $found" "$size"
        field "LVM filesystem $found" "$fstype"
        field "LVM mount $found" "$mount"
    done < <(lsblk -P -o PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null)

    if (( found == 0 )); then
        field "LVM status" "not detected"
        return 0
    fi
    if (( found == 1 )); then
        field "LVM status" "detected (1 logical volume)"
    else
        field "LVM status" "detected ($found logical volumes)"
    fi

    if have lvs; then
        echo "        LVM volume groups:"
        printf "          %-32s %-20s %s\n" "LOGICAL VOLUME" "VG" "SIZE"
        while IFS='|' read -r lv_path vg_name lv_size; do
            lv_path="$(xargs <<< "$lv_path")"
            vg_name="$(xargs <<< "$vg_name")"
            lv_size="$(xargs <<< "$lv_size")"
            [[ -n "$lv_path" ]] || continue
            printf "          %-32s %-20s %s\n" \
                "$lv_path" "$vg_name" "$lv_size"
        done < <(
            lvs --noheadings --separator '|' --options lv_path,vg_name,lv_size \
                2>/dev/null
        )
    else
        field "LVM tools" "not installed; lsblk detected logical volumes"
    fi
}

storage_status_rank() {
    case "$1" in
        CRITICAL) echo 3 ;;
        WARN) echo 2 ;;
        *) echo 1 ;;
    esac
}

storage_raise() {
    local candidate="$1"
    local current_rank candidate_rank

    current_rank="$(storage_status_rank "${STORAGE_VERDICT:-OK}")"
    candidate_rank="$(storage_status_rank "$candidate")"
    if (( candidate_rank > current_rank )); then
        STORAGE_VERDICT="$candidate"
    fi
}

storage_trim() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

storage_numeric_at_least() {
    local value="$1"
    local threshold="$2"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v value="$value" -v threshold="$threshold" 'BEGIN { exit !(value >= threshold) }'
}

filesystem_health_metrics() {
    local source fstype target options used inode mode status xfs_errors kernel_errors
    local found=0

    echo "    Filesystem health:"
    if ! have findmnt; then
        echo "        unavailable (findmnt not found)"
        return 0
    fi
    printf "        %-32s %-10s %-9s %-8s %-8s %-6s %-14s %s\n" \
        "TARGET" "FSTYPE" "STATUS" "USED" "INODE" "MODE" "KERNEL ERRORS" "SOURCE"

    while read -r source fstype target options; do
        [[ -n "$target" && -n "$fstype" ]] || continue

        # Do not turn pseudo-filesystems into storage warnings.
        case "$fstype" in
            autofs|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|pstore|proc|securityfs|sysfs|tmpfs|tracefs)
                continue
                ;;
        esac

        found=$((found + 1))
        used="$(df -P "$target" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
        inode="$(df -Pi "$target" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}')"
        used="${used:-N/A}"
        inode="${inode:-N/A}"
        mode=rw
        [[ ",$options," == *,ro,* ]] && mode=ro
        status=OK

        if storage_numeric_at_least "$used" 95 || storage_numeric_at_least "$inode" 95; then
            status=CRITICAL
        elif storage_numeric_at_least "$used" 90 || storage_numeric_at_least "$inode" 90; then
            status=WARN
        fi

        if [[ "$mode" == ro ]]; then
            storage_raise CRITICAL
            status=CRITICAL
        else
            storage_raise "$status"
        fi

        xfs_errors=0
        kernel_errors="-"
        if [[ "$fstype" == xfs ]] && dmesg >/dev/null 2>&1; then
            xfs_errors="$(dmesg 2>/dev/null | grep -iEc 'XFS.*(error|corrupt|shutdown|log)' || true)"
            [[ "$xfs_errors" =~ ^[0-9]+$ ]] || xfs_errors=0
            kernel_errors="$xfs_errors"
            (( xfs_errors > 0 )) && storage_raise WARN
        fi

        printf "        %-32s %-10s %-9s %-8s %-8s %-6s %-14s %s\n" \
            "$target" "$fstype" "$status" "${used}%" "${inode}%" "$mode" \
            "$kernel_errors" "$source"
    done < <(findmnt -rn -o SOURCE,FSTYPE,TARGET,OPTIONS 2>/dev/null)

    (( found > 0 )) || echo "        none"
}

lvm_health_metrics() {
    local pv_name pv_attr pv_size pv_free
    local vg_name vg_attr vg_size vg_free
    local lv_path lv_attr lv_size pool_lv data_percent metadata_percent
    local found=0 status

    if ! have pvs && ! have vgs && ! have lvs; then
        echo "    LVM health: none"
        return 0
    fi
    echo "    LVM health:"

    if have pvs; then
        printf "        %-26s %-10s %-12s %-12s %-8s\n" "PV" "ATTR" "SIZE" "FREE" "STATUS"
        while IFS='|' read -r pv_name pv_attr pv_size pv_free; do
            pv_name="$(printf '%s' "$pv_name" | storage_trim)"
            pv_attr="$(printf '%s' "$pv_attr" | storage_trim)"
            pv_size="$(printf '%s' "$pv_size" | storage_trim)"
            pv_free="$(printf '%s' "$pv_free" | storage_trim)"
            [[ -n "$pv_name" ]] || continue
            found=$((found + 1))
            status=OK
            if [[ "$pv_attr" == *m* || "$pv_attr" == *r* ]]; then
                status=CRITICAL
                storage_raise CRITICAL
            fi
            printf "        %-26s %-10s %-12s %-12s %-8s\n" \
                "$pv_name" "${pv_attr:-N/A}" "${pv_size:-N/A}" \
                "${pv_free:-N/A}" "$status"
        done < <(pvs --noheadings --separator '|' --options pv_name,pv_attr,pv_size,pv_free 2>/dev/null)
    fi

    if have vgs; then
        printf "        %-26s %-10s %-12s %-12s %-8s\n" "VG" "ATTR" "SIZE" "FREE" "STATUS"
        while IFS='|' read -r vg_name vg_attr vg_size vg_free; do
            vg_name="$(printf '%s' "$vg_name" | storage_trim)"
            vg_attr="$(printf '%s' "$vg_attr" | storage_trim)"
            vg_size="$(printf '%s' "$vg_size" | storage_trim)"
            vg_free="$(printf '%s' "$vg_free" | storage_trim)"
            [[ -n "$vg_name" ]] || continue
            found=$((found + 1))
            status=OK
            if [[ "$vg_attr" == *p* ]]; then
                status=CRITICAL
                storage_raise CRITICAL
            fi
            printf "        %-26s %-10s %-12s %-12s %-8s\n" \
                "$vg_name" "${vg_attr:-N/A}" "${vg_size:-N/A}" \
                "${vg_free:-N/A}" "$status"
        done < <(vgs --noheadings --separator '|' --options vg_name,vg_attr,vg_size,vg_free 2>/dev/null)
    fi

    if have lvs; then
        printf "        %-30s %-10s %-12s %-18s %-12s %-12s %-8s\n" \
            "LV" "ATTR" "SIZE" "POOL" "DATA" "META" "STATUS"
        while IFS='|' read -r lv_path lv_attr lv_size pool_lv data_percent metadata_percent; do
            lv_path="$(printf '%s' "$lv_path" | storage_trim)"
            lv_attr="$(printf '%s' "$lv_attr" | storage_trim)"
            lv_size="$(printf '%s' "$lv_size" | storage_trim)"
            pool_lv="$(printf '%s' "$pool_lv" | storage_trim)"
            data_percent="$(printf '%s' "$data_percent" | storage_trim)"
            metadata_percent="$(printf '%s' "$metadata_percent" | storage_trim)"
            [[ -n "$lv_path" ]] || continue
            found=$((found + 1))
            status=OK

            if [[ "$lv_attr" == *p* ]]; then
                status=CRITICAL
                storage_raise CRITICAL
            fi
            if storage_numeric_at_least "$data_percent" 98 || \
               storage_numeric_at_least "$metadata_percent" 98; then
                status=CRITICAL
                storage_raise CRITICAL
            elif storage_numeric_at_least "$data_percent" 90 || \
                 storage_numeric_at_least "$metadata_percent" 90; then
                [[ "$status" == OK ]] && status=WARN
                storage_raise WARN
            fi

            printf "        %-30s %-10s %-12s %-18s %-12s %-12s %-8s\n" \
                "$lv_path" "${lv_attr:-N/A}" "${lv_size:-N/A}" \
                "${pool_lv:--}" "${data_percent:--}" "${metadata_percent:--}" "$status"
        done < <(lvs --noheadings --separator '|' --options lv_path,lv_attr,lv_size,pool_lv,data_percent,metadata_percent 2>/dev/null)
    fi

    (( found > 0 )) || echo "    LVM health: none"
}

zfs_health_metrics() {
    local pool state capacity fragmentation zread zwrite zcksum scan status found=0

    if ! have zpool; then
        echo "    ZFS health: none"
        return 0
    fi
    echo "    ZFS health:"
    printf "        %-24s %-12s %-12s %-14s %-10s %-10s %-10s %-8s\n" \
        "POOL" "STATE" "CAPACITY" "FRAGMENTATION" "READ" "WRITE" "CHECKSUM" "STATUS"

    while IFS='|' read -r pool state capacity fragmentation; do
        pool="$(printf '%s' "$pool" | storage_trim)"
        state="$(printf '%s' "$state" | storage_trim)"
        capacity="$(printf '%s' "$capacity" | storage_trim)"
        fragmentation="$(printf '%s' "$fragmentation" | storage_trim)"
        [[ -n "$pool" ]] || continue
        found=$((found + 1))
        status=OK

        case "$state" in
            ONLINE) ;;
            DEGRADED) status=WARN; storage_raise WARN ;;
            FAULTED|UNAVAIL|OFFLINE|REMOVED) status=CRITICAL; storage_raise CRITICAL ;;
            *) status=WARN; storage_raise WARN ;;
        esac

        if storage_numeric_at_least "${capacity%%%}" 95; then
            status=CRITICAL
            storage_raise CRITICAL
        elif storage_numeric_at_least "${capacity%%%}" 90; then
            [[ "$status" == OK ]] && status=WARN
            storage_raise WARN
        fi
        if storage_numeric_at_least "${fragmentation%%%}" 80; then
            [[ "$status" == OK ]] && status=WARN
            storage_raise WARN
        fi

        read -r zread zwrite zcksum < <(
            zpool status -Hp -P "$pool" 2>/dev/null \
                | awk -v wanted="$pool" '$1 == wanted && $2 ~ /^(ONLINE|DEGRADED|FAULTED|UNAVAIL|OFFLINE|REMOVED)$/ {print $3, $4, $5; exit}'
        )
        zread="${zread:-0}"; zwrite="${zwrite:-0}"; zcksum="${zcksum:-0}"
        if [[ "$zread" != 0 || "$zwrite" != 0 || "$zcksum" != 0 ]]; then
            status=WARN
            storage_raise WARN
        fi

        scan="$(zpool status "$pool" 2>/dev/null | sed -n 's/^[[:space:]]*scan: //p' | head -n 1)"
        printf "        %-24s %-12s %-12s %-14s %-10s %-10s %-10s %-8s\n" \
            "$pool" "$state" "${capacity:-N/A}" "${fragmentation:-N/A}" \
            "$zread" "$zwrite" "$zcksum" "$status"
        [[ -n "$scan" ]] && storage_kv "scrub" "$scan"
    done < <(zpool list -H -p -o name,health,capacity,fragmentation 2>/dev/null | sed 's/[[:space:]][[:space:]]*/|/g')

    (( found > 0 )) || echo "    ZFS health: none"
}

smart_field() {
    local smart_output="$1"
    local wanted="$2"
    printf '%s\n' "$smart_output" | awk -F: -v wanted="$wanted" '
        {
            key=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted) {
                sub(/^[^:]*:[[:space:]]*/, "")
                gsub(/[[:space:]]+$/, "")
                print
                exit
            }
        }
    '
}

smart_ata_raw() {
    local smart_output="$1"
    local attribute_regex="$2"
    printf '%s\n' "$smart_output" | awk -v attribute_regex="$attribute_regex" '
        $2 ~ attribute_regex { print $10; exit }
    '
}

smart_temperature_number() {
    printf '%s\n' "$1" | sed -n 's/[^0-9-]*\(-\?[0-9][0-9]*\).*/\1/p'
}

smart_temperature_pair_max() {
    printf '%s\n' "$1" | sed -n 's#^[^/]*/[[:space:]]*\(-\?[0-9][0-9]*\).*#\1#p'
}

smart_table_add_row() {
    local disk="$1" model="$2" firmware="$3" health="$4"
    shift 4
    SMART_TABLE_DISKS+=("$disk")
    SMART_TABLE_MODELS+=("$model")
    SMART_TABLE_FIRMWARES+=("$firmware")
    SMART_TABLE_HEALTHS+=("$health")
    SMART_TABLE_TEMPS+=("$1")
    SMART_TABLE_TEMP_STATUS+=("$2")
    SMART_TABLE_TEMP_DELTAS+=("$3")
    SMART_TABLE_CYCLE_MAX+=("$4")
    SMART_TABLE_LIFETIME_MAX+=("$5")
    SMART_TABLE_RECOMMENDED_MAX+=("$6")
    SMART_TABLE_LIMITS+=("$7")
    SMART_TABLE_UNDER_OVER+=("$8")
    SMART_TABLE_POWER_ON+=("$9")
    shift 9
    SMART_TABLE_POWER_CYCLES+=("$1")
    SMART_TABLE_WEAR+=("$2")
    SMART_TABLE_SPARE+=("$3")
    SMART_TABLE_REALLOCATED+=("$4")
    SMART_TABLE_PENDING+=("$5")
    SMART_TABLE_UNCORRECTABLE+=("$6")
    SMART_TABLE_CRC+=("$7")
    SMART_TABLE_MEDIA_ERRORS+=("$8")
    SMART_TABLE_UNSAFE_SHUTDOWNS+=("$9")
    shift 9
    SMART_TABLE_ERROR_LOG+=("$1")
}

smart_health_metrics() {
    local disk device smart_output smart_sct nvme_info model firmware health temperature hours cycles
    local temp_cycle temp_lifetime temp_recommended temp_limit temp_over_limit
    local temp_cycle_max temp_lifetime_max temp_recommended_max temp_limit_max temp_status temp_deviation
    local reallocated pending uncorrectable crc wear spare media_errors unsafe_shutdowns error_entries
    local smart_seen=0 smart_available=0 smart_failed=0
    local temp_display temp_status_display temp_delta_display cycle_max_display lifetime_max_display
    local recommended_max_display limit_display under_over_display
    local power_on_display power_cycles_display wear_display spare_display reallocated_display
    local pending_display uncorrectable_display crc_display media_errors_display unsafe_display error_log_display
    local max_smart_disk=4 max_smart_model=5 max_smart_firmware=8 i

    SMART_TABLE_DISKS=()
    SMART_TABLE_MODELS=()
    SMART_TABLE_FIRMWARES=()
    SMART_TABLE_HEALTHS=()
    SMART_TABLE_TEMPS=()
    SMART_TABLE_TEMP_STATUS=()
    SMART_TABLE_TEMP_DELTAS=()
    SMART_TABLE_CYCLE_MAX=()
    SMART_TABLE_LIFETIME_MAX=()
    SMART_TABLE_RECOMMENDED_MAX=()
    SMART_TABLE_LIMITS=()
    SMART_TABLE_UNDER_OVER=()
    SMART_TABLE_POWER_ON=()
    SMART_TABLE_POWER_CYCLES=()
    SMART_TABLE_WEAR=()
    SMART_TABLE_SPARE=()
    SMART_TABLE_REALLOCATED=()
    SMART_TABLE_PENDING=()
    SMART_TABLE_UNCORRECTABLE=()
    SMART_TABLE_CRC=()
    SMART_TABLE_MEDIA_ERRORS=()
    SMART_TABLE_UNSAFE_SHUTDOWNS=()
    SMART_TABLE_ERROR_LOG=()

    echo "    SMART disk health:"
    if ! have lsblk; then
        echo "        unavailable (lsblk not found)"
        return 0
    fi
    if ! have smartctl && ! have nvme; then
        echo "        unavailable (smartctl/nvme not found)"
        return 0
    fi

    while read -r disk; do
        [[ -n "$disk" ]] || continue
        device="/dev/$disk"
        smart_output=""
        if have smartctl; then
            smart_output="$(smartctl -a "$device" 2>&1 || true)"
            if [[ "$disk" != nvme[0-9]*n[0-9]* ]] && \
               ! grep -q 'Current Temperature:' <<< "$smart_output"; then
                # SCT temperature data is read-only. Some HDDs expose useful
                # current, min/max and over-limit counters only through it.
                smart_sct="$(smartctl -l scttemp "$device" 2>&1 || true)"
                smart_output="$smart_output
$smart_sct"
            fi
        fi

        # smartctl normally supports NVMe too; use nvme-cli when it does not.
        if [[ "$disk" == nvme[0-9]*n[0-9]* ]] && \
           ! grep -qiE 'Model Number:|Critical Warning:|SMART overall-health|SMART Health Status' <<< "$smart_output" && \
           have nvme; then
            smart_output="$(nvme smart-log "$device" 2>&1 || true)"
            if [[ -z "$(smart_field "$smart_output" "Model Number")" ]] && have nvme; then
                nvme_info="$(nvme id-ctrl "$device" 2>/dev/null || true)"
                smart_output="$nvme_info
$smart_output"
            fi
        fi

        model="$(smart_field "$smart_output" "Device Model")"
        [[ -n "$model" ]] || model="$(smart_field "$smart_output" "Model Number")"
        [[ -n "$model" ]] || model="$(smart_field "$smart_output" "Product")"
        [[ -n "$model" ]] || model="$(device_model "$disk")"
        firmware="$(smart_field "$smart_output" "Firmware Version")"
        [[ -n "$firmware" ]] || firmware="$(smart_field "$smart_output" "Firmware Revision")"

        if [[ -z "$smart_output" ]] || ! grep -qiE 'SMART|SCT Status|Critical Warning|Temperature:|Device Model:|Model Number:|Product:' <<< "$smart_output"; then
            smart_failed=$((smart_failed + 1))
            smart_table_add_row "$device" "${model:-N/A}" "${firmware:--}" "N/A" \
                "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-"
            continue
        fi
        smart_available=$((smart_available + 1))
        smart_seen=1

        health="$(printf '%s\n' "$smart_output" | awk -F: '
            /SMART overall-health self-assessment test result:|SMART Health Status:/ {
                sub(/^[^:]*:[[:space:]]*/, ""); print; exit
            }
        ' | storage_trim)"
        if [[ -z "$health" ]]; then
            health="$(smart_field "$smart_output" "Critical Warning")"
            [[ "$health" == 0 ]] && health=OK
            [[ "$health" != OK && -n "$health" ]] && health=WARN
        fi
        if [[ -z "$health" ]]; then
            health=N/A
        elif grep -qiE 'FAILED|CRITICAL|read only|media error' <<< "$health"; then
            storage_raise CRITICAL
            health=CRITICAL
        elif [[ -n "$health" ]] && ! grep -qiE 'PASSED|OK|^0$' <<< "$health"; then
            storage_raise WARN
            health=WARN
        else
            health=OK
        fi

        temperature="$(smart_field "$smart_output" "Current Temperature")"
        [[ -n "$temperature" ]] || temperature="$(smart_field "$smart_output" "Temperature")"
        [[ -n "$temperature" ]] || temperature="$(smart_ata_raw "$smart_output" 'Temperature_Celsius|Airflow_Temperature_Cel|Temperature_Internal')"
        temperature="$(smart_temperature_number "$temperature")"
        temp_cycle="$(smart_field "$smart_output" "Power Cycle Min/Max Temperature")"
        temp_lifetime="$(smart_field "$smart_output" "Lifetime Min/Max Temperature")"
        temp_recommended="$(smart_field "$smart_output" "Min/Max recommended Temperature")"
        temp_limit="$(smart_field "$smart_output" "Min/Max Temperature Limit")"
        [[ -n "$temp_limit" ]] || temp_limit="$(smart_field "$smart_output" "Specified Max Operating Temperature")"
        temp_over_limit="$(smart_field "$smart_output" "Under/Over Temperature Limit Count")"
        temp_cycle_max="$(smart_temperature_pair_max "$temp_cycle")"
        temp_lifetime_max="$(smart_temperature_pair_max "$temp_lifetime")"
        temp_recommended_max="$(smart_temperature_pair_max "$temp_recommended")"
        temp_limit_max="$(smart_temperature_pair_max "$temp_limit")"
        [[ -n "$temp_limit_max" ]] || temp_limit_max="$(smart_temperature_number "$temp_limit")"
        temp_status=OK
        temp_deviation=""

        if [[ "$temperature" =~ ^[0-9]+$ ]]; then
            if [[ "$temp_recommended_max" =~ ^[0-9]+$ ]]; then
                temp_deviation=$((temperature - temp_recommended_max))
                if [[ "$temp_limit_max" =~ ^[0-9]+$ ]] && (( temperature >= temp_limit_max )); then
                    temp_status=CRITICAL
                    storage_raise CRITICAL
                elif (( temperature >= temp_recommended_max )); then
                    temp_status=WARN
                    storage_raise WARN
                fi
            elif [[ "$disk" == nvme[0-9]*n[0-9]* ]]; then
                # Fallback only when the device does not report a limit.
                if (( temperature >= 85 )); then
                    temp_status=CRITICAL
                    storage_raise CRITICAL
                elif (( temperature >= 75 )); then
                    temp_status=WARN
                    storage_raise WARN
                fi
            else
                # Conservative HDD fallback; vendor-reported limits take precedence.
                if (( temperature >= 60 )); then
                    temp_status=CRITICAL
                    storage_raise CRITICAL
                elif (( temperature >= 55 )); then
                    temp_status=WARN
                    storage_raise WARN
                fi
            fi

            # A previous excursion is useful evidence even when the disk has
            # cooled down before the snapshot was taken.
            if [[ "$temp_over_limit" =~ /([1-9][0-9]*)$ ]]; then
                temp_status=WARN
                storage_raise WARN
            elif [[ "$temp_lifetime_max" =~ ^[0-9]+$ && "$temp_recommended_max" =~ ^[0-9]+$ ]] && \
                 (( temp_lifetime_max >= temp_recommended_max )); then
                temp_status=WARN
                storage_raise WARN
            fi
        fi
        hours="$(smart_field "$smart_output" "Power On Hours")"
        [[ -n "$hours" ]] || hours="$(smart_ata_raw "$smart_output" 'Power_On_Hours')"
        cycles="$(smart_field "$smart_output" "Power Cycles")"
        [[ -n "$cycles" ]] || cycles="$(smart_ata_raw "$smart_output" 'Power_Cycle_Count')"

        reallocated="$(smart_ata_raw "$smart_output" 'Reallocated_Sector_Ct')"
        pending="$(smart_ata_raw "$smart_output" 'Current_Pending_Sector')"
        uncorrectable="$(smart_ata_raw "$smart_output" 'Offline_Uncorrectable|Uncorrectable')"
        crc="$(smart_ata_raw "$smart_output" 'UDMA_CRC_Error_Count')"
        wear="$(smart_field "$smart_output" "Percentage Used")"
        spare="$(smart_field "$smart_output" "Available Spare")"
        media_errors="$(smart_field "$smart_output" "Media and Data Integrity Errors")"
        unsafe_shutdowns="$(smart_field "$smart_output" "Unsafe Shutdowns")"
        error_entries="$(smart_field "$smart_output" "Error Information Log Entries")"

        if [[ "$pending" =~ ^[1-9][0-9]*$ || "$uncorrectable" =~ ^[1-9][0-9]*$ || "$media_errors" =~ ^[1-9][0-9]*$ ]]; then
            storage_raise CRITICAL
            health=CRITICAL
        elif [[ "$reallocated" =~ ^[1-9][0-9]*$ || "$crc" =~ ^[1-9][0-9]*$ ]]; then
            [[ "$health" == OK ]] && health=WARN
            storage_raise WARN
        fi

        temp_display="-"; [[ -n "$temperature" ]] && temp_display="${temperature}C"
        temp_status_display="-"; [[ -n "$temperature" ]] && temp_status_display="$temp_status"
        temp_delta_display="-"; [[ -n "$temp_deviation" ]] && temp_delta_display="$(printf "%+dC" "$temp_deviation")"
        cycle_max_display="-"; [[ -n "$temp_cycle_max" ]] && cycle_max_display="${temp_cycle_max}C"
        lifetime_max_display="-"; [[ -n "$temp_lifetime_max" ]] && lifetime_max_display="${temp_lifetime_max}C"
        recommended_max_display="-"; [[ -n "$temp_recommended_max" ]] && recommended_max_display="${temp_recommended_max}C"
        limit_display="-"; [[ -n "$temp_limit_max" ]] && limit_display="${temp_limit_max}C"
        under_over_display="${temp_over_limit:--}"
        power_on_display="${hours:--}"; [[ -n "$hours" ]] && power_on_display="${hours}h"
        power_cycles_display="${cycles:--}"
        wear_display="${wear:--}"; spare_display="${spare:--}"
        reallocated_display="${reallocated:--}"; pending_display="${pending:--}"
        uncorrectable_display="${uncorrectable:--}"; crc_display="${crc:--}"
        media_errors_display="${media_errors:--}"; unsafe_display="${unsafe_shutdowns:--}"
        error_log_display="${error_entries:--}"
        smart_table_add_row "$device" "${model:-N/A}" "${firmware:--}" "$health" \
            "$temp_display" "$temp_status_display" "$temp_delta_display" "$cycle_max_display" \
            "$lifetime_max_display" "$recommended_max_display" "$limit_display" "$under_over_display" \
            "$power_on_display" "$power_cycles_display" "$wear_display" "$spare_display" \
            "$reallocated_display" "$pending_display" "$uncorrectable_display" "$crc_display" \
            "$media_errors_display" "$unsafe_display" "$error_log_display"
    done < <(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')

    if (( ${#SMART_TABLE_DISKS[@]} == 0 )); then
        echo "        unavailable (virtual disk, unsupported device, or insufficient permissions)"
        return 0
    fi

    for ((i = 0; i < ${#SMART_TABLE_DISKS[@]}; i++)); do
        ((${#SMART_TABLE_DISKS[i]} > max_smart_disk)) && max_smart_disk=${#SMART_TABLE_DISKS[i]}
        ((${#SMART_TABLE_MODELS[i]} > max_smart_model)) && max_smart_model=${#SMART_TABLE_MODELS[i]}
        ((${#SMART_TABLE_FIRMWARES[i]} > max_smart_firmware)) && max_smart_firmware=${#SMART_TABLE_FIRMWARES[i]}
    done

    echo "    SMART overview:"
    printf "        %-*s  %-*s  %-*s  %-8s  %-8s  %-10s  %-9s  %-10s  %-10s  %-10s  %-8s  %s\n" \
        "$max_smart_disk" DISK "$max_smart_model" MODEL "$max_smart_firmware" FIRMWARE \
        HEALTH TEMP TEMP_STATUS TEMP_DELTA CYCLE_MAX LIFETIME_MAX RECOMMENDED_MAX LIMIT UNDER_OVER
    for ((i = 0; i < ${#SMART_TABLE_DISKS[@]}; i++)); do
        printf "        %-*s  %-*s  %-*s  %-8s  %-8s  %-10s  %-9s  %-10s  %-10s  %-10s  %-8s  %s\n" \
            "$max_smart_disk" "${SMART_TABLE_DISKS[i]}" "$max_smart_model" "${SMART_TABLE_MODELS[i]}" \
            "$max_smart_firmware" "${SMART_TABLE_FIRMWARES[i]}" "${SMART_TABLE_HEALTHS[i]}" \
            "${SMART_TABLE_TEMPS[i]}" "${SMART_TABLE_TEMP_STATUS[i]}" "${SMART_TABLE_TEMP_DELTAS[i]}" \
            "${SMART_TABLE_CYCLE_MAX[i]}" "${SMART_TABLE_LIFETIME_MAX[i]}" \
            "${SMART_TABLE_RECOMMENDED_MAX[i]}" "${SMART_TABLE_LIMITS[i]}" "${SMART_TABLE_UNDER_OVER[i]}"
    done

    echo
    echo "    SMART lifetime and error counters:"
    printf "        %-*s  %-12s  %-13s  %-8s  %-8s  %-10s  %-8s  %-10s  %-8s  %-10s  %-12s  %s\n" \
        "$max_smart_disk" DISK POWER_ON POWER_CYCLES WEAR SPARE REALLOC PENDING UNCORRECTABLE CRC MEDIA_ERRORS UNSAFE_SHUTDOWNS ERROR_LOG
    for ((i = 0; i < ${#SMART_TABLE_DISKS[@]}; i++)); do
        printf "        %-*s  %-12s  %-13s  %-8s  %-8s  %-10s  %-8s  %-10s  %-8s  %-10s  %-12s  %s\n" \
            "$max_smart_disk" "${SMART_TABLE_DISKS[i]}" "${SMART_TABLE_POWER_ON[i]}" \
            "${SMART_TABLE_POWER_CYCLES[i]}" "${SMART_TABLE_WEAR[i]}" "${SMART_TABLE_SPARE[i]}" \
            "${SMART_TABLE_REALLOCATED[i]}" "${SMART_TABLE_PENDING[i]}" "${SMART_TABLE_UNCORRECTABLE[i]}" \
            "${SMART_TABLE_CRC[i]}" "${SMART_TABLE_MEDIA_ERRORS[i]}" \
            "${SMART_TABLE_UNSAFE_SHUTDOWNS[i]}" "${SMART_TABLE_ERROR_LOG[i]}"
    done
}

storage_health_report() {
    STORAGE_VERDICT=OK
    echo
    filesystem_health_metrics
    echo
    lvm_health_metrics
    echo
    zfs_health_metrics
    echo
    smart_health_metrics
    echo
    echo "    Storage verdict: $STORAGE_VERDICT"
}

load_metrics() {
    local load1 load5 load15 cpu_cores per_cpu1 per_cpu5 per_cpu15 trend interpretation
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || {
        load1="0.00"; load5="0.00"; load15="0.00";
    }
    cpu_cores="$(nproc 2>/dev/null || echo 1)"
    [[ "$cpu_cores" -gt 0 ]] || cpu_cores=1
    per_cpu1="$(awk -v load_value="$load1" -v cpu_count="$cpu_cores" 'BEGIN { printf "%.2f", load_value / cpu_count }')"
    per_cpu5="$(awk -v load_value="$load5" -v cpu_count="$cpu_cores" 'BEGIN { printf "%.2f", load_value / cpu_count }')"
    per_cpu15="$(awk -v load_value="$load15" -v cpu_count="$cpu_cores" 'BEGIN { printf "%.2f", load_value / cpu_count }')"
    trend="$(awk -v first_load="$load1" -v middle_load="$load5" -v last_load="$load15" 'BEGIN {
        if (first_load > middle_load && middle_load >= last_load) print "increasing";
        else if (first_load < middle_load && middle_load <= last_load) print "decreasing";
        else print "stable/mixed";
    }')"
    interpretation="$(awk -v first_load="$load1" -v cpu_count="$cpu_cores" 'BEGIN {
        if (first_load < cpu_count * 0.7) print "low demand relative to CPU count";
        else if (first_load < cpu_count) print "moderate demand relative to CPU count";
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
    local line netid state recv_q send_q local_address peer_address process

    if have ss; then
        {
            printf "%-6s %-8s %-6s %-6s %-30s %-22s %s\n" \
                "Netid" "State" "Recv-Q" "Send-Q" "Local Address:Port" "Peer Address:Port" "Process"

            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                read -r netid state recv_q send_q local_address peer_address process <<< "$line"
                printf "%-6s %-8s %-6s %-6s %-30s %-22s %s\n" \
                    "$netid" "$state" "$recv_q" "$send_q" "$local_address" \
                    "$peer_address" "$process"
            done < <(ss -tuplnH 2>/dev/null)
        } | indent + 4 || echo "    Cannot read listening ports"
    else
        echo "    ss is not available"
    fi
}

disk_report() {
    echo -e "\n# Disk"
    disk_metrics
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

docker_volume_size_bytes() {
    local volume="$1"
    local mountpoint size_kib size_bytes

    mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume" \
        2>/dev/null | head -n 1)"
    [[ -n "$mountpoint" && -d "$mountpoint" ]] || return 1

    size_bytes="$(du -sx -B1 -- "$mountpoint" 2>/dev/null \
        | awk 'NR == 1 {print $1; exit}')"
    if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$size_bytes"
        return 0
    fi

    size_kib="$(du -sxk -- "$mountpoint" 2>/dev/null \
        | awk 'NR == 1 {print $1; exit}')"
    [[ "$size_kib" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$((size_kib * 1024))"
}

docker_volumes_report() {
    local rows named_rows dangling_rows total named_count anonymous_count
    local dangling_count anonymous_dangling_count anonymous_rows
    local name driver size_bytes total_bytes measured_count unmeasured_count
    local short_name
    local -a volume_sizes=()

    rows="$(docker volume ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null || true)"
    if [[ -z "$rows" ]]; then
        echo "    (none)"
        return 0
    fi

    named_rows="$(printf '%s\n' "$rows" | awk -F '\t' \
        '$1 !~ /^[[:xdigit:]]{64}$/ {print}')"
    echo "    Named volumes:"
    if [[ -n "$named_rows" ]]; then
        printf "        %-48s %s\n" "NAME" "DRIVER"
        while IFS=$'\t' read -r name driver; do
            [[ -n "$name" ]] || continue
            printf "        %-48s %s\n" "$name" "$driver"
        done <<< "$named_rows"
    else
        echo "        (none)"
    fi

    total="$(printf '%s\n' "$rows" | awk 'NF {count++} END {print count + 0}')"
    named_count="$(printf '%s\n' "$named_rows" \
        | awk 'NF {count++} END {print count + 0}')"
    anonymous_count=$((total - named_count))
    dangling_rows="$(docker volume ls -qf dangling=true 2>/dev/null || true)"
    dangling_count="$(printf '%s\n' "$dangling_rows" \
        | awk 'NF {count++} END {print count + 0}')"
    anonymous_dangling_count="$(printf '%s\n' "$dangling_rows" \
        | awk '$1 ~ /^[[:xdigit:]]{64}$/ {count++} END {print count + 0}')"
    anonymous_rows="$(printf '%s\n' "$rows" \
        | awk -F '\t' '$1 ~ /^[[:xdigit:]]{64}$/ {print $1}')"

    echo
    echo "    Anonymous volumes:"
    if (( anonymous_count > 0 )); then
        printf "        Total:    %s\n" "$anonymous_count"
        printf "        In use:   %s\n" "$((anonymous_count - anonymous_dangling_count))"
        printf "        Dangling: %s\n" "$anonymous_dangling_count"

        total_bytes=0
        measured_count=0
        unmeasured_count=0
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if size_bytes="$(docker_volume_size_bytes "$name")"; then
                total_bytes=$((total_bytes + size_bytes))
                measured_count=$((measured_count + 1))
                volume_sizes+=("$size_bytes"$'\t'"$name")
            else
                unmeasured_count=$((unmeasured_count + 1))
            fi
        done <<< "$anonymous_rows"

        if (( measured_count > 0 )); then
            printf "        Disk usage: %.2f GiB\n" \
                "$(awk -v bytes="$total_bytes" 'BEGIN {print bytes / 1024 / 1024 / 1024}')"
            if (( unmeasured_count > 0 )); then
                printf "        Unmeasured:  %s\n" "$unmeasured_count"
            fi

            echo
            echo "        Largest anonymous volumes:"
            printf '%s\n' "${volume_sizes[@]}" \
                | sort -nr -k1,1 \
                | head -n 5 \
                | while IFS=$'\t' read -r size_bytes name; do
                    short_name="${name:0:12}..."
                    printf "            %-10s %s\n" \
                        "$(bytes_to_human "$size_bytes")" "$short_name"
                done
        else
            echo "        Disk usage: unavailable"
        fi
    else
        echo "        (none)"
    fi
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
    docker_volumes_report
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
    docker_volumes_report

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
