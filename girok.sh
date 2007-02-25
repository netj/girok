#!/usr/bin/env bash
# girok -- incremental backup tool
# Author: Jaeho Shin <netj@sparcs.org>
# Refined: 2006-04-06
# Created: 2003-10-29
Version=2.0.2

set -e

# useful vocabularies
Base=$(cd "`dirname "$0"`" && pwd)
Here=$PWD
Args=("$@")
Name=`basename "$0"`
err() { echo "$Name: $@" >&2; false; }

# detect OS and setup environment
timefmt="%Y-%m-%dT%H:%M:%S"
case `uname` in
    *BSD)
    tar=gtar
    eval 'mtime() { stat -f %Sm -t '"$timefmt"' $1; }'
    chronological() {
        # XXX: must be very inefficient :(
        local buf=`mktemp /tmp/girok.chronological.XXXXXX`
        cat >$buf
        if [ -s $buf ]; then
            xargs -0 ls -tr <$buf
        fi
        rm -f $buf
    }
    ;;
    *) # GNU is default
    tar=tar
    eval 'mtime() { date -r $1 +'"$timefmt"'; }'
    chronological() { xargs -0r ls -tr; }
    ;;
esac
tar=${GIROK_TAR:-$tar}
eval 'tar() { command '"'${tar//"'"/"'\\''"}'"' "$@"; }'


# GNU tar is very essential!
if ! { tar --version | grep 'Free Software Foundation\|GNU'; } &>/dev/null; then
    err "girok needs GNU tar, set GIROK_TAR to its path"
fi


# temporary directory & cleanup ###############################################
tmp=
need_tmpdir() {
    [ -d "$tmp" ] || tmp=`mktemp -d \
        "${1:-${TMPDIR:-${Root:-/tmp}}}/girok.XXXXXX"`
}
todos=()
before_exit() { todos=("${todos[@]}" "$@"); }
cleanup() {
    trap "exit $?" EXIT
    trap "" ERR HUP INT TERM
    # do scheduled jobs
    local cmd=
    for cmd in "${todos[@]}"; do
        eval "$cmd"
    done
    # cleanup tmp?
    ! [ -d "$tmp" ] || rm -rf "$tmp"
    # all done, let's get out
    exit
}
trap cleanup EXIT ERR HUP INT TERM


# repository ##################################################################
under_the_repository() {
    is_girok_repo() { [ -f "$1/config" -a -d "$1/archive/" ]; }
    Root=
    for r in "$GIROKROOT" "$Base"; do
        if is_girok_repo "$r"; then
            Root=$r
            break
        fi
    done
    if [ -d "$Root" ]; then
        Config="$Root/config"
        Archive="$Root/archive"
        cd "$Archive"
    else
        err "Set GIROKROOT to a path to girok repository"
    fi
}

foreach_backup() {
    local line=0 rest= prefix= period= options= paths=
    while read; do
        let ++line
        [ "$REPLY" = "${REPLY#\#}" -o -z "$REPLY" ] || continue
        case "$REPLY" in
            '') ;;
            *'	'*) # archive definition
            rest=$REPLY
            prefix=${rest%%	*}
            rest=${rest#$prefix	}
            periodspec=${rest%%	*}
            rest=${rest#$periodspec	}
            options=${rest%%	*}
            paths=${rest#$options	}
            if [ -n "$prefix" -a -n "$periodspec" -a -n "$paths" ]; then
                "$@"
            else
                echo "$Config: line $line: syntax error" >&2
            fi
            ;;
            *=*) # value definition
            eval "export $REPLY"
            ;;
        esac
    done <"$Config"
}


###############################################################################
backup() {
    usage() {
        cat <<EOF
girok $Version -- perform multiple backups
Usage: $Name { <prefix> }

Create girok archives for <prefix>es defined in config.
Each line in config defines an archive series.  Each must have four
fields separated by tab character: prefix, period, options, and paths.
Lines that begin with a \# are ignored.  Each archive is created under
archive/ with the specified prefix, period, and options by girok(1).

For example, the following defines an archive series that will be stored as
archive/home/netj-*-*.tar.gpg.
-->8--
home/netj	%m/3	-e netj	/home/netj
--8<--
See girok(1) for more information about periods and options.
EOF
        [ $# -gt 0 ] && err "$@"
        exit 2
    }
    [ $# -gt 0 ] || usage

    under_the_repository
    need_tmpdir

    echo "girok $Version"
    echo "$Name ${Args[@]}"
    echo "begins at `date +'%F %T %z'`"
    echo
    before_exit 'echo "ends   at `date +"%F %T %z"`"'

    echo "= backups ="
    local failure=0
    run_girok() {
        local a=
        for a in "${Args[@]}"; do
            [ `expr "$prefix" : "$a"` -eq ${#prefix} ] || continue
            printf "* %-16s" "$prefix:"
            if (eval "set -e; \
                girok $options $prefix $periodspec $paths" &>"$tmp/o"); then
                valueof() { grep "^ $1: " "$tmp/o" | sed -e "s/^ $1: //"; }
                printf "%28s %5s" "`valueof archive`" `valueof size`
                echo " `valueof options`"
            else
                echo FAILED
                let ++failure
                cat "$tmp/o" 2>/dev/null
            fi
        done
    }
    foreach_backup run_girok
    echo

    echo "= disk usages ="
    df -h `find . -type d` | tail -n +2 | sort | uniq | sed -e 's/^/* /'
    echo

    return $failure
}


###############################################################################
recover() {
    usage() {
        cat <<EOF
girok $Version -- recover files
Usage: $Name [ -t [[CC]YY]MMDDhhmm[.ss] ] { <path> }

Finds and extracts given paths from girok archives,
from the most recent backup before the given time.
Current date and time are used if not specified.
EOF
        # TODO: show recoverable paths from Config
        # foreach_backup show_paths
        [ $# -gt 0 ] && err "$@"
        exit
    }
    # process options
    while getopts "t:" o; do
        case "$o" in
            t) when=$OPTARG ;;
        esac
    done
    shift $(($OPTIND - 1))
    [ $# -gt 0 ] || usage

    under_the_repository
    need_tmpdir /tmp

    # prepare timestamp
    local when=${when:-`date +%Y%m%d%H%M.%S`}
    local timestamp="$tmp/timestamp"
    touch -m -t $when "$timestamp" 2>/dev/null ||
        usage "specify time in [[CC]YY]MMDDhhmm[.ss]"

    extract_from() {
        local arc=$1
        case "$arc" in
            *.tar.gz)  untar "$arc" -z                          ;;
            *.tar.bz2) untar "$arc" -j                          ;;
            *.tar)     untar "$arc"                             ;;
            # TODO rememeber and reuse passphrase for key?
            *.tar.gpg) gpg --quiet --decrypt "$arc" | untar -   ;;
            *) err "$arc: not supported" || true ;;
        esac
    }
    try_recovery() {
        # find requested files which may be in this archive series
        local p a
        declare -a qs=()
        for p in `eval "echo $paths"`; do
            for a in "${Args[@]}"; do
                [ `expr "$a" : "$p"` -eq ${#p} ] ||
                [ `expr "$p" : "$a"` -eq ${#a} ] || continue
                qs=("${qs[@]}" "${a#/}")
            done
        done
        [ ${#qs[@]} -gt 0 ] || return 0
        echo -n "$prefix: recovering ${qs[@]}"
        # find the base archive (the most recent one)
        local arc=`find "$prefix-"*.0.* -type f ! -newer "$timestamp" \
                    -print0 2>/dev/null | chronological | tail -1`
        local period=${arc%.0.*}
        if ! [ -f "$arc" ]; then
            echo
            err "$prefix: none exists for $when"
            return 0
        fi
        # TODO: check list of deleted files?
        untar() { tar -C "$Here" -vxpf "$@" "${qs[@]}"; }
        # and extract files from successive archives
        echo " from $period.*.*"
        while [ -f "$arc" ]; do
            # extract from $arc
            echo " searching $arc (`mtime "$arc"`) (^\\=skip)"
            set +e; extract_from "$arc"; set -e
            # pick the next oldest one for arc
            arc=`find "$period".*.* -type f \
                    -newer "$arc" ! -newer "$timestamp" \
                    -print0 2>/dev/null | chronological | head -1`
        done
    }

    foreach_backup try_recovery

    true
}


###############################################################################
girok() {
    usage() {
        cat <<EOF
girok $Version
Usage: $Name { <option> } <prefix> %fmt/# { <path> | <option-for-tar> }

Option:
  -h          show this usage
  -o user     owner user for new files
  -g group    owner group for new files
  -m mode     access mode for new files
  -e keyid    compress and encrypt with GnuPG
  -j          compress with bzip2
  -z          compress with gzip

Period:
  You must specify a rotation period as "%fmt/#".
  "%fmt" is the format string used in date, e.g. %m, %U, %d, and
  "#" is the number of periods to keep until next rotation.

  Path where to place the file is determined by appending
  \`date +%fmt\` to <prefix>, i.e. "<prefix>-\`date +%fmt\`".
  For example, "%U/4" means, restart every week and keep them for 3 weeks,
  and "%m/6" means, restart every month and keep them for 5 months.

Environment Variable:
  * TMPDIR for holding temporary files
  * GNUPGHOME or HOME for encryption
  * GIROK_TAR for path to GNU tar
EOF
        exit 2
    }

    # default options
    umask 077
    ulimit -c 0
    local mode=${Mode:-a=,u=r}
    local owner=${Owner:-root}
    local group=${Group:-}
    local encrypt=${Encrypt:-}
    local compress=gzip

    # process options
    while getopts "hm:o:zjirp:e:" c; do
        case "$c" in
            z) compress=gzip ;;
            j) compress=bzip2 ;;
            e) encrypt=$OPTARG ;;
            o) owner=$OPTARG ;;
            g) group=$OPTARG ;;
            m) mode=$OPTARG ;;
            h) usage ;;
        esac
    done
    shift $(($OPTIND - 1))
    [ $# -ge 3 ] || usage
    local prefix=$1 periodspec=$2; shift 2
    declare -a paths=("$@")


    # check environment
    #  GnuPG
    if [ -n "$encrypt" ]; then
        if ! [ -d "$HOME/.gnupg" -o -d "$GNUPGHOME" ]; then
            err "For encryption, HOME or at least GNUPGHOME must be set"
        fi
        # TODO: existence of gpg key
    fi
    # TODO: existence of owner, group


    # setup option dependent values
    local suffix="tar"
    declare -a taropts=()
    addtaropt() { taropts=("${taropts[@]}" "$@"); }
    # process encrypt/compress option
    if [ -n "$encrypt" ]; then
        suffix="tar.gpg"
    else
        case "$compress" in
            bzip2) addtaropt -j; suffix="tar.bz2" ;;
            gzip)  addtaropt -z; suffix="tar.gz" ;;
            "")    ;;
            *)     err "$compress: unknown compression type" ;;
        esac
    fi

    need_tmpdir

    # determine current period
    local periodfmt=${periodspec%/*}
    local periodcnt=${periodspec#*/}
    local period=`date +"$periodfmt" | sed -e 's/^0*//g'`
    period=`printf "%0${#periodcnt}d" $(($period % $periodcnt))`
    period=${period:-0}
    # determine whether to restart or not
    local restart=false
    if [ "$period@$periodspec" != "`cat "$prefix.last" 2>/dev/null`" ]; then
        echo "$period@$periodspec" >"$tmp/last"
        restart=true
    fi
    # prepare incremental timestamp
    touch "$tmp/inc"
    addtaropt -g "$tmp/inc"
    $restart || cp -pf "$prefix.inc" "$tmp/inc"
    chmod +w "$tmp/inc"


    # put everything into the archive
    justtar() {
        tar -cf - "${taropts[@]}" "${paths[@]}"
    }
    encrypttar() {
        justtar | \
        gpg --encrypt --batch --quiet --always-trust --default-recipient-self \
            ${encrypt:+--recipient "$encrypt"}
    }
    local tarcmd=justtar
    [ -z "$encrypt" ] || tarcmd=encrypttar
    if ! $tarcmd >"$tmp/arc"; then
        # TODO: handle error codes
        true
    fi
    [ -s "$tmp/arc" ] || err "failed creating archive"
    # TODO: maintain a file list, or list of deleted files


    # determine sub-period id
    local id=0 arc=
    if ! $restart; then
        # find base
        arc=`find "$prefix-$period.0".* -type f | head -1`
        while [ -f "$arc" ]; do
            let ++id
            # find an incremental archive having this id
            if find "$prefix-$period.$id".* -type f -newer "$arc" \
                -print0 2>/dev/null >"$tmp/found" && [ -s "$tmp/found" ]; then
                arc=`xargs -0 ls -tr <"$tmp/found" | head -1`
            else
                break
            fi
        done
        rm -f "$tmp/found"
    fi
    arc="$prefix-$period.$id.$suffix"
    # put it at the right place
    set_attr() {
        local f=
        for f in "$@"; do
            [ -e "$f" ] || continue
            [ $EUID -ne 0 ] || chown $owner "$f"
            [ -z "$group" ] || chgrp $group "$f"
            chmod $mode "$f"
        done
    }
    set_attr "$tmp/arc" "$tmp/inc" "$tmp/last"
    mkdir -p -m 755 "`dirname "$prefix"`"
    if $restart; then
        rm -f "$prefix-$period".*.*
        mv -f "$tmp/last" "$prefix.last"
    fi
    mv -f "$tmp/arc" "$arc"
    mv -f "$tmp/inc" "$prefix.inc"


    # finish message
    echo "girok done:"
    echo " archive: $arc"
    echo " size: `du -h "$arc" | cut -f1`"
    echo -n " options:"
    $restart && echo -n " restarted" || echo -n " incremental"
    [ -z "$encrypt" ] || echo -n " encrypted"
    echo


    true
}


###############################################################################
install() {
    usage() {
        cat <<EOF
girok $Version
Usage: $Name <repository-path> ...

EOF
    }
    [ $# -gt 0 ] || usage
    local r=
    for r in "$@"; do
        mkdir -pv "$r/archive"
        cp -fv "$0" "$r/girok"
        chmod -v +x "$r/girok"
        ln -sfv girok "$r/backup"
        ln -sfv girok "$r/recover"
        if ! [ -f "$r/config" ]; then
            cat >"$r/config" <<EOF
# girok configuration example
# Author: Jaeho Shin <netj@sparcs.org>
# Created: 2006-06-03

## Parameters
Owner=root
Group=
Mode=a=,u=r

## Archive series
# prefix	period	options	paths to backup
freebsd/system	%U/4	-e netj	{,/usr/local}/etc /var/{cron,at,named/etc/namedb} /boot/loader.conf /usr/src/sys/i386/conf/EGO /root /home/backup/{config,girok,backup,recover}
debian/system	%U/4	-e netj	/etc /var/spool/cron /boot/grub/menu.lst /root /var/lib/dpkg /backup/{girok,backup,recover,config}
debian/home	%m/3	-e netj	--exclude=/home/netj/.Trash /home/netj
mail/spool	%m/2	-e netj	/var/mail
mail/mailman	%m/2		/usr/local/mailman/{data,lists,archives}

# vim:ts=16:sts&:sw&:noet
EOF
        fi
    done
}


###############################################################################
case "$Name" in
    backup|recover|girok)   "$Name" "$@"    ;;
    *)                      install "$@"     ;;
esac

