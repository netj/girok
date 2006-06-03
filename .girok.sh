#! bash
# girok -- common & compatibility parts
# Author: Jaeho Shin <netj@sparcs.org>
Version=1.20060603

#BackupTmp=/tmp
#BackupRoot=/home/backup
#BackupArchive=/home/backup/archive
#BackupTable=/etc/backuptab
#BackupPerm="a=,u=r"
#BackupOwner=root
#BackupGroup=backup

Base=$(cd "`dirname "$0"`" && pwd)
Here=$PWD
Args=("$@")
Name=`basename "$0"`

err() { echo "$Name: $@" >&2; exit 1; }


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
if ! { tar --version | grep 'Free Software Foundation'; } &>/dev/null; then
    err "GNU tar unavailable, set GIROK_TAR to its path"
fi
