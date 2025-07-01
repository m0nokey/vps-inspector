#!/usr/bin/env bash
export LC_ALL=C

# default options
SHOW_HIDDEN=0; ONLY_DIRS=0; MAX_DEPTH=999
INCLUDE=(); EXCLUDE=()
FULL_PATH=0; CLASSIFY=0
SHOW_PERM=0; SHOW_USER=0; SHOW_GROUP=0
DIRS_FIRST=0; PACKAGE_MODE=0; FILE_MODE=0
TOP_N=0; DFREPORT=0; SNAPSHOT=0
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
# Usage: indent add N   # add N spaces
#        indent rm  N   # remove up to N spaces
indent() {
    MODE="$1"
    NUM="$2"
    if [[ "$MODE" == "add" ]]; then
        sed "s/^/$(printf '%*s' "$NUM")/"
    elif [[ "$MODE" == "rm" ]]; then
        sed -E "s/^ {0,$NUM}//"
    fi
}

# usage information
usage() {
    cat <<EOF | indent rm 4 >&2
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
    echo -e "# System snapshot"
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
            fi

            echo "CPU cores: $(nproc)"
            read _ TOTAL_MEM USED_MEM _ < <(free -h | awk '/^Mem:/')
            echo "Memory: $USED_MEM/$TOTAL_MEM"
    } | indent add 4

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
    } | indent add 4

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
    } | indent add 4

    # custom system services
    echo -e "\n# Custom system services"
    {
        find /etc/systemd/system -maxdepth 1 -type f -name '*.service' | xargs -r basename
    } | indent 4

    # user-defined systemd services
    echo -e "\n# User-defined systemd services"
    {
        awk -F: '$3>=1000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd \
        | while read -r S_USER; do
            echo "User: $S_USER"
            su - "$S_USER" -c 'systemctl --user list-unit-files --type=service --no-pager' 2>/dev/null || echo "(none)"
            echo
        done
    } | indent add 4

    echo -e "\n# Top 10 by %MEM"
    {
        ps aux --sort=-%mem | head -n 11
    } | indent add 4

    echo -e "\n# Block devices"
    {
        lsblk -d -o NAME,SIZE,TYPE,MODEL
    } | indent add 4

    echo -e "\n# Filesystems & partitions"
    {
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
    } | indent add 4

    echo -e "\n# Disk usage warnings (>90%)"
    {
        mapfile -t DF_WARN < <(df -h | awk '$5+0>90{print "WARN:", $0}')
        if (( ${#DF_WARN[@]} )); then
            printf "%s\n" "${DF_WARN[@]}"
        else
            echo "(none)"
        fi
    } | indent add 4

    echo -e "\n# Inode usage warnings (>90%)"
    {
        mapfile -t INO_WARN < <(df -i | awk '$5+0>90{print "WARN: inode usage high:", $0}')
        if (( ${#INO_WARN[@]} )); then
            printf "%s\n" "${INO_WARN[@]}"
        else
            echo "(none)"
        fi
    } | indent add 4

    echo -e "\n# Top 10 largest logs"
    {
        du -sh /var/log/* 2>/dev/null | sort -hr | head -n 10 | awk '{size=$1; $1=""; sub(/^ */, ""); printf "%-8s %s\n", size, $0}'
    } | indent add 4


    echo -e "\n# Broken symlinks under /usr"
    {
        mapfile -t SYMLINKS < <(find /usr -xtype l)
        if (( ${#SYMLINKS[@]} )); then
            printf "%s\n" "${SYMLINKS[@]}"
        else
            echo "(none)"
        fi
    } | indent add 4

    echo -e "\n# Zombie processes"
    {
        mapfile -t ZOMBIES < <(ps -ef | awk '$8=="Z"')
        if (( ${#ZOMBIES[@]} )); then
            printf "%s\n" "${ZOMBIES[@]}"
        else
            echo "(none)"
        fi
    } | indent add 4

    #  network & DNS Information
    ## interface details
    echo -e "\n# Interface details"
    {
        local PRIMARY_IFACE="$(ip route | awk '/^default/ {print $5; exit}')"
        local IPV4_ADDR="$(ip -4 addr show "$PRIMARY_IFACE" | grep -Po '(?<=inet )\d+(\.\d+){3}')"
        local GATEWAY="$(ip route | awk '/^default/ {print $3; exit}')"
        echo "Primary interface:   $PRIMARY_IFACE"
        echo "IPv4 address:        $IPV4_ADDR"
        echo "Gateway:             $GATEWAY"
    } | indent add 4

    ## DNS resolver
    echo -e "\n# DNS resolver"
    {
        local DNS_RESOLVER="none detected"
        for SVC in systemd-resolved unbound bind9 dnsmasq cloudflared adguardhome; do
            if systemctl is-active --quiet "$SVC"; then
                case "$SVC" in
                    systemd-resolved) DNS_RESOLVER="systemd-resolved" ;;
                    unbound)          DNS_RESOLVER="Unbound" ;;
                    bind9)            DNS_RESOLVER="BIND9" ;;
                    dnsmasq)          DNS_RESOLVER="dnsmasq" ;;
                    cloudflared)      DNS_RESOLVER="cloudflared (DoH proxy)" ;;
                    adguardhome)      DNS_RESOLVER="AdGuard Home" ;;
                esac
                break
            fi
        done
        echo "Resolver service:   $DNS_RESOLVER"
    } | indent add 4

    ## nameservers
    echo -e "\n# Nameservers"
    {
        awk '/^nameserver/ { printf("    %s\n", $2) }' /etc/resolv.conf
    } | indent add 4

    ## routes
    echo -e "\n# Routes"
    {
        ip route
    } | indent add 4

    ## listening TCP/UDP ports
    echo -e "\n# Listening TCP/UDP ports"
    {
        # header
        printf "%-6s %-8s %-6s %-6s %-22s %-22s %s\n" "Netid" "State" "Recv-Q" "Send-Q" "Local Address:Port" "Peer Address:Port" "Process"
        # data
        ss -tupln | tail -n +2 | awk '{
            printf "%-6s %-8s %-6s %-6s %-22s %-22s %s\n", $1, $2, $3, $4, $5, $6, $7
        }'
    } | indent add 4

    # IPv4 NAT table & rules
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
    } | indent add 4
    
    # IPv6 NAT table & rules
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
    } | indent add 4

    echo -e "\n# Docker containers"
    {
        if command -v docker &>/dev/null; then
            docker ps -a
        else
            echo "Docker is not installed"
        fi
    } | indent add 4

    echo -e "\n# Package install/upgrade history"
    {
        printf "%-10s %-8s %-8s %-15s %-5s %-12s %-12s %s\n" "DATE" "TIME" "ACTION" "PACKAGE" "ARCH" "OLD_VERSION" "NEW_VERSION" "STATUS"

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
    } | column -t | indent add 4
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
