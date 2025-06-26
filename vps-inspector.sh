#!/usr/bin/env bash
export LC_ALL=C

# default options
SHOW_HIDDEN=0; ONLY_DIRS=0; MAX_DEPTH=999
INCLUDE=(); EXCLUDE=()
FULL_PATH=0; CLASSIFY=0
SHOW_PERM=0; SHOW_USER=0; SHOW_GROUP=0
DIRS_FIRST=0; PACKAGE_MODE=0; FILE_MODE=0
TOP_N=0; DFREPORT=0; SNAPSHOT=0
TARGET=""; PKGFILES=(); FILE_PATH=""
declare -a SIZES=()
COMMON_PATHS=(/var/log /home /tmp)

# olors & counters
RESET=$'\e[0m'; DIR_COL=$'\e[1;34m'; LINK_COL=$'\e[1;36m'
EXEC_COL=$'\e[1;32m'; ARCH_COL=$'\e[1;31m'; ORANGE=$'\e[38;5;214m'
COUNT_DIRS=0; COUNT_FILES=0

# function to indent data lines by 4 spaces
indent() {
    sed 's/^/    /'
}

# usage information
usage() {
    cat <<EOF | perl -pe 's/^ {4}//' >&2
    Usage: $0 [options] [path|package|file]

    Options:
      -a               Show hidden files
      -d               Show directories only
      -L depth         Set recursion depth (default unlimited)
      -P include_regex Include only paths matching regex
      -I exclude_regex Exclude paths matching regex
      -f               Print full paths instead of names
      -F               Append indicators: '/' for dirs, '*' for executables, '@' for links, '#' for archives
      -p               Show permissions before name
      -u               Show owner before name
      -g               Show group before name
      --dirsfirst      List directories before files

      -t N, --top N    Show top N largest files in /var/log,/home,/tmp
      -r, --dfreport   Show df -h and df -i for target
      -s, --snapshot   Quick system snapshot
      -h, --help       Show this help and exit

    Examples:
      # List all files (including hidden)
      $0 -a

      # List directories only up to depth 2 in /etc
      $0 -d -L 2 /etc

      # Show only .conf files in current dir
      $0 -P '\.conf$'

      # Exclude any path containing /bin
      $0 -I '/bin'

      # Print full paths and classify entries
      $0 -f -F

      # After tree, show top 5 largest entries
      $0 -t 5

      # Report disk usage and inodes for /var
      $0 -r /var

      # Perform a quick system snapshot
      $0 -s
EOF
    exit 1
}

# define tree function
print_tree() {
    local DIR="$1" DEPTH="$2" PREFIX="$3"
    (( DEPTH>MAX_DEPTH )) && return

    local HIDE_ARGS=()
    (( SHOW_HIDDEN==0 )) && HIDE_ARGS=(-not -name '.*')

    mapfile -d '' -t ENTRIES < <(
        find "$DIR" -mindepth 1 -maxdepth 1 "${HIDE_ARGS[@]}" -print0 2>/dev/null | sort -z --version-sort --ignore-case
    )

    if (( DIRS_FIRST )); then
        local DLIST=() FLIST=()
        for E in "${ENTRIES[@]}"; do
            [[ -d $E ]] && DLIST+=("$E") || FLIST+=("$E")
        done
        ENTRIES=("${DLIST[@]}" "${FLIST[@]}")
    fi

    local TOTAL=${#ENTRIES[@]} IDX=0
    for ENTRY in "${ENTRIES[@]}"; do
        (( IDX++ ))
        if (( FILE_MODE )); then
            [[ "$(realpath "$ENTRY")" != "$FILE_PATH" ]] && continue
        fi

        local NAME=${ENTRY##*/}
        if (( PACKAGE_MODE )) && [[ -z ${PKGSET[$ENTRY]} ]]; then continue; fi
        if (( ${#INCLUDE[@]} )); then
            local OK=0
            for RX in "${INCLUDE[@]}"; do [[ $ENTRY =~ $RX ]] && OK=1; done
            (( OK==0 )) && continue
        fi
        if (( ${#EXCLUDE[@]} )); then
            local SKIP=0
            for RX in "${EXCLUDE[@]}"; do [[ $ENTRY =~ $RX ]] && SKIP=1; done
            (( SKIP )) && continue
        fi
        if (( ONLY_DIRS )) && [[ ! -d $ENTRY ]]; then continue; fi

        if (( TOP_N>0 )); then
            local SZ=$(stat -c '%s' "$ENTRY" 2>/dev/null || echo 0)
            SIZES+=("$SZ|$ENTRY")
        fi

        read -r PERM OWN GRP < <(stat -c '%A %U %G' "$ENTRY" 2>/dev/null) || PERM=''
        local PTR CHILD SUF INFO=""
        if (( IDX==TOTAL )); then PTR='└──'; CHILD='   '; else PTR='├──'; CHILD='│  '; fi
        (( SHOW_PERM )) && INFO+="$PERM "
        (( SHOW_USER )) && INFO+="$OWN "
        (( SHOW_GROUP )) && INFO+="$GRP "
        if (( CLASSIFY )); then
            [[ -L $ENTRY ]] && SUF='@' || [[ -d $ENTRY ]] && SUF='/' || [[ -x $ENTRY ]] && SUF='*' || [[ $NAME =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]] && SUF='#'
        fi

        if [[ -L $ENTRY ]]; then
            (( COUNT_FILES++ ))
            local REL COL2
            REL=$(readlink "$ENTRY")
            if [[ -d $ENTRY ]]; then COL2=$DIR_COL
            elif [[ -x $ENTRY ]]; then COL2=$EXEC_COL
            elif [[ $REL =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]]; then COL2=$ARCH_COL; else COL2=$RESET; fi
            printf '%s%s %b%s%b -> %b%s%b %b%s%b\n' "$INFO" "$PREFIX$PTR" "$LINK_COL" "$NAME" "$RESET" "$COL2" "$REL" "$RESET" "$LINK_COL" "$SUF" "$RESET"
            continue
        fi

        if [[ -d $ENTRY && ! -r $ENTRY ]]; then
            (( COUNT_DIRS++ ))
            printf '%s%s %b%s%b %b[error]%b\n' "$INFO" "$PREFIX$PTR" "$DIR_COL" "$NAME" "$RESET" "$ORANGE" "$RESET"
            continue
        fi

        local COL DISP="$NAME"
        if [[ -d $ENTRY ]]; then COL=$DIR_COL; (( COUNT_DIRS++ ));
        elif [[ -x $ENTRY ]]; then COL=$EXEC_COL; (( COUNT_FILES++ ));
        elif [[ $NAME =~ \.(tar|tgz|zip|rar|gz|bz2|xz)$ ]]; then COL=$ARCH_COL; (( COUNT_FILES++ ));
        else COL=$RESET; (( COUNT_FILES++ )); fi
        (( FULL_PATH )) && DISP="$ENTRY"
        printf '%s%s %b%s%b %b%s%b\n' "$INFO" "$PREFIX$PTR" "$COL" "$DISP" "$RESET" "$COL" "$SUF" "$RESET"

        [[ -d $ENTRY ]] && print_tree "$ENTRY" $((DEPTH+1)) "$PREFIX$CHILD"
    done
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
                vt=$(systemd-detect-virt)
                case "$vt" in
                    none)
                        echo "Server type: Dedicated server" ;;
                    lxc|docker|openvz|podman|systemd-nspawn)
                        echo "Server type: Container ($vt)" ;;
                    *)
                        echo "Server type: Virtual machine ($vt)" ;;
                esac
            fi
    
            echo "CPU cores: $(nproc)"
            read _ TOTAL_MEM USED_MEM _ < <(free -h | awk '/^Mem:/')
            echo "Memory: $USED_MEM/$TOTAL_MEM"
    } | indent

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
    } | indent
    
    # cron jobs
    echo -e "\n# Cron jobs"
    {
        echo "SYSTEM CRONTAB (/etc/crontab & /etc/cron.d)"
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
    } | indent
    
    # custom system services
    echo -e "\n# Custom system services"
    {
        find /etc/systemd/system -maxdepth 1 -type f -name '*.service' \
            | xargs -r basename
    } | indent
    
    # user-defined systemd services
    echo -e "\n# User-defined systemd services"
    {
        awk -F: '$3>=1000 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd \
        | while read -r S_USER; do
            echo "User: $S_USER"
            su - "$S_USER" -c 'systemctl --user list-unit-files --type=service --no-pager' 2>/dev/null \
                || echo "(none)"
            echo
        done
    } | indent

    echo -e "\n# Top 10 by %MEM"
    {
        ps aux --sort=-%mem | head -n 11
    } | indent

    echo -e "\n# Block devices"
    {
        lsblk -d -o NAME,SIZE,TYPE,MODEL
    } | indent

    echo -e "\n# Filesystems & partitions"
    {
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
    } | indent

    echo -e "\n# Disk usage warnings (>90%)"
    {
        mapfile -t DF_WARN < <(df -h | awk '$5+0>90{print "WARN:", $0}')
        if (( ${#DF_WARN[@]} )); then
            printf "%s\n" "${DF_WARN[@]}"
        else
            echo "(none)"
        fi
    } | indent

    echo -e "\n# Inode usage warnings (>90%)"
    {
        mapfile -t INO_WARN < <(df -i | awk '$5+0>90{print "WARN: inode usage high:", $0}')
        if (( ${#INO_WARN[@]} )); then
            printf "%s\n" "${INO_WARN[@]}"
        else
            echo "(none)"
        fi
    } | indent

    echo -e "\n# Top 10 largest logs"
    {
        du -sh /var/log/* 2>/dev/null | sort -hr | head -n 10 | awk '{size=$1; $1=""; sub(/^ */, ""); printf "%-8s %s\n", size, $0}'
    } | indent


    echo -e "\n# Broken symlinks under /usr"
    {
        mapfile -t SYMLINKS < <(find /usr -xtype l)
        if (( ${#SYMLINKS[@]} )); then
            printf "%s\n" "${SYMLINKS[@]}"
        else
            echo "(none)"
        fi
    } | indent

    echo -e "\n# Zombie processes"
    {
        mapfile -t ZOMBIES < <(ps -ef | awk '$8=="Z"')
        if (( ${#ZOMBIES[@]} )); then
            printf "%s\n" "${ZOMBIES[@]}"
        else
            echo "(none)"
        fi
    } | indent

    #  network & DNS Information
    ## interface details
    echo -e "\n# Interface details"
    {
        PRIMARY_IFACE="$(ip route | awk '/^default/ {print $5; exit}')"
        IPV4_ADDR="$(ip -4 addr show "$PRIMARY_IFACE" | grep -Po '(?<=inet )\d+(\.\d+){3}')"
        GATEWAY="$(ip route | awk '/^default/ {print $3; exit}')"
        echo "Primary interface:   $PRIMARY_IFACE"
        echo "IPv4 address:        $IPV4_ADDR"
        echo "Gateway:             $GATEWAY"
    } | indent
    
    ## DNS resolver
    echo -e "\n# DNS resolver"
    {
        DNS_RESOLVER="none detected"
        for svc in systemd-resolved unbound bind9 dnsmasq cloudflared adguardhome; do
            if systemctl is-active --quiet "$svc"; then
                case "$svc" in
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
    } | indent
    
    ## nameservers
    echo -e "\n# Nameservers"
    {
        awk '/^nameserver/ { printf("    %s\n", $2) }' /etc/resolv.conf
    } | indent
    
    ## routes
    echo -e "\n# Routes"
    {
        ip route
    } | indent
    
    ## listening TCP/UDP ports
    echo -e "\n# Listening TCP/UDP ports"
    {
        # header
        printf "%-6s %-8s %-6s %-6s %-22s %-22s %s\n" \
            "Netid" "State" "Recv-Q" "Send-Q" "Local Address:Port" "Peer Address:Port" "Process"
        # data
        ss -tupln | tail -n +2 | awk '{ 
            printf "%-6s %-8s %-6s %-6s %-22s %-22s %s\n", 
                $1, $2, $3, $4, $5, $6, $7 
        }'
    } | indent

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
    } | indent
    
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
    } | indent

    echo -e "\n# Docker containers"
    {
        if command -v docker &>/dev/null; then
            docker ps -a
        else
            echo "Docker is not installed"
        fi
    } | indent

    echo -e "\n# Package install/upgrade history"
    {
        printf "%-10s %-8s %-8s %-15s %-5s %-12s %-12s %s\n" \
            "DATE" "TIME" "ACTION" "PACKAGE" "ARCH" "OLD_VERSION" "NEW_VERSION" "STATUS"
    
        grep -hE ' install | upgrade ' /var/log/dpkg.log* 2>/dev/null \
          | awk '{
                n = split($4,a,":");
                pkg  = a[1];
                arch = a[2];
                printf "%s %s %s %s %s %s %s\n", $1, $2, $3, pkg, arch, $5, $6
            }' \
          | sort -k1,1 -k2,2 \
          | while read DATE TIME ACTION PACKAGE ARCH OLD_REV NEW_REV; do
                STATUS=$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null \
                         | grep -q "installed" && echo "+" || echo "-")
                printf "%-10s %-8s %-8s %-15s %-5s %-12s %-12s %s\n" \
                    "$DATE" "$TIME" "$ACTION" "$PACKAGE" "$ARCH" "$OLD_REV" "$NEW_REV" "$STATUS"
            done
    } | column -t | indent
}

# parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) SHOW_HIDDEN=1; shift;;
        -d) ONLY_DIRS=1; shift;;
        -L) [[ "$2" =~ ^[0-9]+$ ]] || usage; MAX_DEPTH=$2; shift 2;;
        -P) INCLUDE+=("$2"); shift 2;;
        -I) EXCLUDE+=("$2"); shift 2;;
        -f) FULL_PATH=1; shift;;
        -F) CLASSIFY=1; shift;;
        -p) SHOW_PERM=1; shift;;
        -u) SHOW_USER=1; shift;;
        -g) SHOW_GROUP=1; shift;;
        --dirsfirst) DIRS_FIRST=1; shift;;
        -t|--top) TOP_N=$2; shift 2;;
        -r|--dfreport) DFREPORT=1; shift;;
        -s|--snapshot) SNAPSHOT=1; shift;;
        -h|--help) usage;;
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
# if argument is an executable in PATH, treat as file
if command -v "$TARGET" &>/dev/null; then
    FILE_MODE=1
    FILE_PATH=$(command -v "$TARGET")
    ROOT=$(dirname "$FILE_PATH")
elif [[ -f "$TARGET" ]]; then
    FILE_MODE=1
    FILE_PATH=$(realpath "$TARGET")
    ROOT=$(dirname "$FILE_PATH")
elif [[ -d "$TARGET" ]]; then
    ROOT="$TARGET"
elif command -v pacman &>/dev/null && pacman -Qi "$TARGET" &>/dev/null; then
    PACKAGE_MODE=1
    mapfile -t PKGFILES < <(pacman -Ql "$TARGET" | awk '{print $2}')
    ROOT="/"
elif command -v dpkg-query &>/dev/null && dpkg-query -W -f='${Status}' "$TARGET" 2>/dev/null | grep -q "install ok installed"; then
    PACKAGE_MODE=1
    mapfile -t PKGFILES < <(dpkg-query -L "$TARGET")
    ROOT="/"
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
    printf '%b%s%b\n' "$DIR_COL" "${ROOT:-$TARGET}" "$RESET"
    print_tree "${ROOT:-$TARGET}" 1 ""
    echo; printf '%d directories, %d files\n' "$COUNT_DIRS" "$COUNT_FILES"
fi

if (( TOP_N>0 )); then
    echo; echo "Top $TOP_N largest files in ${COMMON_PATHS[*]} (readable):"
    du -x -b "${COMMON_PATHS[@]}" 2>/dev/null | sort -rn -k1 | head -n "$TOP_N" | awk '{cmd="numfmt --to=iec "$1; cmd|getline h; close(cmd); printf "%8s  %s\n",h,$2}'
fi

if (( DFREPORT )); then
    echo; echo "Disk space for $ROOT:"; df -h "$ROOT"
    echo; echo "Inodes for $ROOT:"; df -i "$ROOT"
fi
