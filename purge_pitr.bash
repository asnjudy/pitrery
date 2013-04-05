#!@BASH@
#
# Copyright 2011 Nicolas Thauvin. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

usage() {
    echo "`basename $0` cleans old PITR backups"
    echo "usage: `basename $0` [options] [hostname]"
    echo "options:"
    echo "    -L           Purge a local store"
    echo "    -l label     Label to process"
    echo "    -b dir       Backup directory"
    echo "    -n host      Host storing archived WALs"
    echo "    -X dir       Archived WALs directory"
    echo
    echo "    -m count     Keep this number of backups"
    echo "    -d days      Purge backup older than this number of days"
    echo
    echo "    -?           Print help"
    echo
    exit $1
}

# Hard coded configuration 
local_backup="no"
backup_root=/var/lib/pgsql/backups
label_prefix="pitr"
local_xlog="no"
xlog_dir=/var/lib/pgsql/archived_xlog

info() {
    echo "INFO: $*"
}

warn() {
    echo "WARNING: $*" 1>&2
}

error() {
    echo "ERROR: $*" 1>&2
    exit 1
}

# CLI options
args=`getopt "Ll:b:n:X:m:d:?" $*`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) local_backup="yes"; shift;;
	-l) label_prefix=$2; shift 2;;
	-b) backup_root=$2; shift 2;;
	-n) xlog_host=$2; shift 2;;
	-X) xlog_dir=$2; shift 2;;
	-m) max_count=$2; shift 2;;
	-d) max_days=$2; shift 2;;

        -\?) usage 1;;
        --) shift; break;;
    esac
done

target=$1
# Destination host is mandatory unless the backup is local
if [ -z "$target" ] && [ $local_backup != "yes" ]; then
    echo "ERROR: missing target host" 1>&2
    usage 1
fi

# Either -m or -d must be specified
if [ -z "$max_count" -a -z "$max_days" ]; then
    echo "ERROR: missing purge condition. Use -m or -d." 1>&2
    usage 1
fi

# Create our tmp directory
tmp_dir=`mktemp -d -t pg_pitr.XXXXXXXXXX`
if [ $? != 0 ]; then
    error "could not create temporary directory"
fi

# Check if bakcup host is local and prepare for IPv6 if needed
LC_ALL=C /sbin/ifconfig | grep -qE "(addr:${target}[[:space:]]|inet6 addr: ${target}/)"
if [ $? = 0 ]; then
    local_backup="yes"
fi

# When the host storing the WAL files is not given, use the host of the backups
if [ -z "$xlog_host" ]; then
    if [ $local_backup = "yes" ]; then
	local_xlog="yes"
    else
	xlog_host=$target
    fi
fi

# Prepare the IPv6 address for use with SSH
echo $target | grep -q ':' && target="[${target}]"

# Get the list of backups. We need to know the stop time of each
# backup to select the good ones, at this time the base backup is
# considered usable.
if [ $local_backup = "yes" ]; then
    list=`ls -d $backup_root/$label_prefix/[0-9]* 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/"
    fi

    for d in $list; do
	stoptime=`cat $d/backup_label | grep '^STOP TIME: ' | sed -e 's/STOP TIME: //'`
	if [ -z "$stoptime" ]; then
	    warn "could not get stop time from $d/backup_label"
	    continue
	fi

	echo "$d|$stoptime" >> $tmp_dir/backup_list
    done
else
    list=`ssh $target "ls -d $backup_root/$label_prefix/[0-9]*" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $backup_root/$label_prefix/ on $target"
    fi

    for d in $list; do
	stoptime=`ssh $target "cat $d/backup_label" 2>/dev/null | grep '^STOP TIME: ' | sed -e 's/STOP TIME: //'`
	if [ -z "$stoptime" ]; then
	    warn "could not get stop time from $d/backup_label"
	    continue
	fi

	echo "$d|$stoptime" >> $tmp_dir/backup_list
    done
fi

# Purge: specified backup count overrides the max number of days
if [ -n "$max_count" ]; then
    # Get the list of backup directory but the last $max_count'th
    remove_list=`echo $list | sort -n | tr ' ' '\n' | head -n -$max_count`
    if [ -n "$remove_list" ]; then
	for dir in $remove_list; do
	    if [ $local_backup = "yes" ]; then
		info "purging $dir"
		rm -rf $dir
		if [ $? != 0 ]; then
		    warn "unable to remove $dir"
		fi
	    else
		info "purging $dir"
		ssh $target "rm -rf $dir"
		if [ $? != 0 ]; then
		    warn "unable to remove $target:$dir"
		fi
	    fi
	done
    else
	info "no backup to purge"
    fi
else
    if [ -n "$max_days" ]; then
	# Find the limiting date from now and the specified number of days
	ldate=`date --date="-$max_days day" +%s`

	cat $tmp_dir/backup_list | while read line; do
	    dir=`echo $line | cut -d'|' -f 1`
	    date=`echo $line | cut -d'|' -f 2`
	    bdate=`date -d "$date" '+%s' 2>/dev/null`
	    
	    if [ $bdate -lt $ldate ]; then
		if [ $local_backup = "yes" ]; then
		    info "purging $dir"
		    rm -rf $dir
		    if [ $? != 0 ]; then
			warn "Unable to remove $dir"
		    fi
		else
		    info "purging $dir"
		    ssh $target "rm -rf $dir"
		    if [ $? != 0 ]; then
			warn "Unable to remove $target:$dir" 1>&2
		    fi
		fi
	    fi
	done
    fi
fi

# To be able to purge the archived xlogs, the backup_label of the oldest backup
# is needed to find the oldest xlog file to keep.

# First get the backup_label, it contains the name of the oldest WAL file to keep
if [ $local_backup = "yes" ]; then
    backup_label=`ls $backup_root/$label_prefix/[0-9]*/backup_label 2>/dev/null | head -1`
    if [ -z "$backup_label" ]; then
	warn "could not find any backup in $backup_root/$label_prefix/"
	info "if you chose to remove all backups, WAL files must be removed manually"
	rm -rf $tmp_dir
	exit 0
    fi
else
    remote_backup_label=`ssh $target "ls -d $backup_root/$label_prefix/[0-9]*/backup_label" 2>/dev/null | head -1`
    if [ $? != 0 ]; then
	warn "could not list the content of $backup_root/$label_prefix/ on $source"
    fi
    
    if [ -n "$remote_backup_label" ]; then
   	scp $target:$remote_backup_label $tmp_dir >/dev/null
	if [ $? != 0 ]; then
	    error "could not copy backup label from $target"
	fi
	backup_label=$tmp_dir/backup_label
    else
	warn "could not find the backup label of the oldest backup, WAL files won't be purged"
	info "if you chose to remove all backups, WAL files must be removed manually"
	rm -rf $tmp_dir
	exit 0
    fi
fi

# Extract the name of the WAL file from the backup history file
wal_file=`grep '^START WAL LOCATION' $backup_label | cut -d' ' -f 6 | sed -e 's/[^0-9A-F]//g'`
max_wal_num=$((16#$wal_file))

info "purging WAL files older than `basename $wal_file .gz`"

# List the WAL files and remove the old ones based on their name
# which are ordered in time by their naming scheme
if [ $local_xlog = "yes" ]; then
    wal_list=`ls $xlog_dir 2>/dev/null | grep  '^[0-9AF]'`
    if [ $? != 0 ]; then
	error "could not list the content of $xlog_dir"
    fi
    for wal in $wal_list; do
	w=`basename $wal .gz`
	# Exclude history and backup label files from the listing
	echo $w | grep -q '\.'
	if [ $? != 0 ]; then
	    wal_num=$(( 16#$w ))
	    if [ $wal_num -lt $max_wal_num ]; then
		# Remove the WAL file and possible the backup history file
		rm $xlog_dir/$w*.gz
		if [ $? != 0 ]; then
		    warn "unable to remove $w" 1>&2
		fi
	    fi
	fi
    done
else
    wal_list=`ssh $xlog_host "ls $xlog_dir | grep  '^[0-9AF]'" 2>/dev/null`
    if [ $? != 0 ]; then
	error "could not list the content of $xlog_dir on $xlog_host"
    fi
    for wal in $wal_list; do
	w=`basename $wal .gz`
	# Exclude history and backup label files
	echo $w | grep -q '\.'
	if [ $? != 0 ]; then
	    wal_num=$(( 16#$w ))
	    if [ $wal_num -lt $max_wal_num ]; then
		ssh $xlog_host "rm $xlog_dir/$w*.gz"
		if [ $? != 0 ]; then
		    warn "Unable to remove $w on $xlog_host"
		fi
	    fi
	fi
    done
fi

# Clean temporary directory
if [ -d "$tmp_dir" ]; then
    rm -rf $tmp_dir
fi

info "done"