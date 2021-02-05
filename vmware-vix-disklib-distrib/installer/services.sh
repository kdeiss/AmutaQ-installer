#!/usr/bin/env bash
#
# Copyright 1998-2011 VMware, Inc.  All rights reserved.
#
# This script manages the services needed to run VMware software
#

# Basic support for IRIX style chkconfig
###
# chkconfig: 235 19 08
# description: Manages the services needed to run VMware software
###

# Basic support for the Linux Standard Base Specification 1.3
# Used by insserv and other LSB compliant tools.
### BEGIN INIT INFO
# Provides: VMware
# Required-Start: $network $syslog
# Required-Stop:
# Default-Start: 2 3 5
# Default-Stop: 0 6
# Short-Description: Manages the services needed to run VMware software
# Description: Manages the services needed to run VMware software
### END INIT INFO

# BEGINNING_OF_UTIL_DOT_SH
#!/bin/sh
#
# Copyright 2005-2011 VMware, Inc.  All rights reserved.
#
# A few utility functions used by our shell scripts.  Some expect the settings
# database to already be loaded and evaluated.

vmblockmntpt="/proc/fs/vmblock/mountPoint"
vmblockfusemntpt="/var/run/vmblock-fuse"

vmware_failed() {
  if [ "`type -t 'echo_failure' 2>/dev/null`" = 'function' ]; then
    echo_failure
  else
    echo -n "$rc_failed"
  fi
}

vmware_success() {
  if [ "`type -t 'echo_success' 2>/dev/null`" = 'function' ]; then
    echo_success
  else
    echo -n "$rc_done"
  fi
}

# Execute a macro
vmware_exec() {
  local msg="$1"  # IN
  local func="$2" # IN
  shift 2

  echo -n '   '"$msg"

  # On Caldera 2.2, SIGHUP is sent to all our children when this script exits
  # I wanted to use shopt -u huponexit instead but their bash version
  # 1.14.7(1) is too old
  #
  # Ksh does not recognize the SIG prefix in front of a signal name
  if [ "$VMWARE_DEBUG" = 'yes' ]; then
    (trap '' HUP; "$func" "$@")
  else
    (trap '' HUP; "$func" "$@") >/dev/null 2>&1
  fi
  if [ "$?" -gt 0 ]; then
    vmware_failed
    echo
    return 1
  fi

  vmware_success
  echo
  return 0
}

# Execute a macro in the background
vmware_bg_exec() {
  local msg="$1"  # IN
  local func="$2" # IN
  shift 2

  if [ "$VMWARE_DEBUG" = 'yes' ]; then
    # Force synchronism when debugging
    vmware_exec "$msg" "$func" "$@"
  else
    echo -n '   '"$msg"' (background)'

    # On Caldera 2.2, SIGHUP is sent to all our children when this script exits
    # I wanted to use shopt -u huponexit instead but their bash version
    # 1.14.7(1) is too old
    #
    # Ksh does not recognize the SIG prefix in front of a signal name
    (trap '' HUP; "$func" "$@") 2>&1 | logger -t 'VMware[init]' -p daemon.err &

    vmware_success
    echo
    return 0
  fi
}

# This is a function in case a future product name contains language-specific
# escape characters.
vmware_product_name() {
  echo 'VMware VIX DiskLib API'
  exit 0
}

# This is a function in case a future product contains language-specific
# escape characters.
vmware_product() {
  echo 'vix-disklib'
  exit 0
}

is_dsp()
{
   # This is the current way of indicating it is part of a
   # distribution-specific install.  Currently only applies to Tools.
   [ -e "$vmdb_answer_LIBDIR"/dsp ]
}

# They are a lot of small utility programs to create temporary files in a
# secure way, but none of them is standard. So I wrote this
make_tmp_dir() {
  local dirname="$1" # OUT
  local prefix="$2"  # IN
  local tmp
  local serial
  local loop

  tmp="${TMPDIR:-/tmp}"

  # Don't overwrite existing user data
  # -> Create a directory with a name that didn't exist before
  #
  # This may never succeed (if we are racing with a malicious process), but at
  # least it is secure
  serial=0
  loop='yes'
  while [ "$loop" = 'yes' ]; do
    # Check the validity of the temporary directory. We do this in the loop
    # because it can change over time
    if [ ! -d "$tmp" ]; then
      echo 'Error: "'"$tmp"'" is not a directory.'
      echo
      exit 1
    fi
    if [ ! -w "$tmp" -o ! -x "$tmp" ]; then
      echo 'Error: "'"$tmp"'" should be writable and executable.'
      echo
      exit 1
    fi

    # Be secure
    # -> Don't give write access to other users (so that they can not use this
    # directory to launch a symlink attack)
    if mkdir -m 0755 "$tmp"'/'"$prefix$serial" >/dev/null 2>&1; then
      loop='no'
    else
      serial=`expr $serial + 1`
      serial_mod=`expr $serial % 200`
      if [ "$serial_mod" = '0' ]; then
        echo 'Warning: The "'"$tmp"'" directory may be under attack.'
        echo
      fi
    fi
  done

  eval "$dirname"'="$tmp"'"'"'/'"'"'"$prefix$serial"'
}

# Removes "stale" device node
# On udev-based systems, this is never needed.
# On older systems, after an unclean shutdown, we might end up with
# a stale device node while the kernel driver has a new major/minor.
vmware_rm_stale_node() {
   local node="$1"  # IN
   if [ -e "/dev/$node" -a "$node" != "" ]; then
      local node_major=`ls -l "/dev/$node" | awk '{print \$5}' | sed -e s/,//`
      local node_minor=`ls -l "/dev/$node" | awk '{print \$6}'`
      if [ "$node_major" = "10" ]; then
         local real_minor=`cat /proc/misc | grep "$node" | awk '{print \$1}'`
         if [ "$node_minor" != "$real_minor" ]; then
            rm -f "/dev/$node"
         fi
      else
         local node_name=`echo $node | sed -e s/[0-9]*$//`
         local real_major=`cat /proc/devices | grep "$node_name" | awk '{print \$1}'`
         if [ "$node_major" != "$real_major" ]; then
            rm -f "/dev/$node"
         fi
      fi
   fi
}

# Checks if the given pid represents a live process.
# Returns 0 if the pid is a live process, 1 otherwise
vmware_is_process_alive() {
  local pid="$1" # IN

  ps -p $pid | grep $pid > /dev/null 2>&1
}

# Check if the process associated to a pidfile is running.
# Return 0 if the pidfile exists and the process is running, 1 otherwise
vmware_check_pidfile() {
  local pidfile="$1" # IN
  local pid

  pid=`cat "$pidfile" 2>/dev/null`
  if [ "$pid" = '' ]; then
    # The file probably does not exist or is empty. Failure
    return 1
  fi
  # Keep only the first number we find, because some Samba pid files are really
  # trashy: they end with NUL characters
  # There is no double quote around $pid on purpose
  set -- $pid
  pid="$1"

  vmware_is_process_alive $pid
}

# Note:
#  . Each daemon must be started from its own directory to avoid busy devices
#  . Each PID file doesn't need to be added to the installer database, because
#    it is going to be automatically removed when it becomes stale (after a
#    reboot). It must go directly under /var/run, or some distributions
#    (RedHat 6.0) won't clean it
#

# Terminate a process synchronously
vmware_synchrone_kill() {
   local pid="$1"    # IN
   local signal="$2" # IN
   local second

   kill -"$signal" "$pid"

   # Wait a bit to see if the dirty job has really been done
   for second in 0 1 2 3 4 5 6 7 8 9 10; do
      vmware_is_process_alive "$pid"
      if [ "$?" -ne 0 ]; then
         # Success
         return 0
      fi

      sleep 1
   done

   # Timeout
   return 1
}

# Kill the process associated to a pidfile
vmware_stop_pidfile() {
   local pidfile="$1" # IN
   local pid

   pid=`cat "$pidfile" 2>/dev/null`
   if [ "$pid" = '' ]; then
      # The file probably does not exist or is empty. Success
      return 0
   fi
   # Keep only the first number we find, because some Samba pid files are really
   # trashy: they end with NUL characters
   # There is no double quote around $pid on purpose
   set -- $pid
   pid="$1"

   # First try a nice SIGTERM
   if vmware_synchrone_kill "$pid" 15; then
      return 0
   fi

   # Then send a strong SIGKILL
   if vmware_synchrone_kill "$pid" 9; then
      return 0
   fi

   return 1
}

# Determine if SELinux is enabled
isSELinuxEnabled() {
   if [ "`cat /selinux/enforce 2> /dev/null`" = "1" ]; then
      echo "yes"
   else
      echo "no"
   fi
}

# Runs a command and retries under the provided SELinux context if it fails
vmware_exec_selinux() {
   local command="$1"
   # XXX We should probably ask the user at install time what context to use
   # when we retry commands.  unconfined_t is the correct choice for Red Hat.
   local context="unconfined_t"
   local retval

   $command
   retval=$?
   if [ $retval -ne 0 -a "`isSELinuxEnabled`" = 'yes' ]; then
      runcon -t $context -- $command
      retval=$?
   fi

   return $retval
}

# Start the blocking file system.  This consists of loading the module and
# mounting the file system.
vmware_start_vmblock() {
   mkdir -p -m 1777 /tmp/VMwareDnD

   # Try FUSE first, fall back on in-kernel module.
   vmware_start_vmblock_fuse && return 0

   vmware_exec 'Loading module' vmware_load_module $vmblock
   exitcode=`expr $exitcode + $?`
   # Check to see if the file system is already mounted.
   if grep -q " $vmblockmntpt vmblock " /etc/mtab; then
       # If it is mounted, do nothing
       true;
   else
       # If it's not mounted, mount it
       vmware_exec_selinux "mount -t vmblock none $vmblockmntpt"
   fi
}

# Stop the blocking file system
vmware_stop_vmblock() {
    # Check if the file system is mounted and only unmount if so.
    # Start with FUSE-based version first, then legacy one.
    #
    # Vmblock-fuse dev path could be /var/run/vmblock-fuse,
    # or /run/vmblock-fuse. Bug 758526.
    if grep -q "/run/vmblock-fuse fuse\.vmware-vmblock " /etc/mtab; then
       # if it's mounted, then unmount it
       vmware_exec_selinux "umount $vmblockfusemntpt"
    fi
    if grep -q " $vmblockmntpt vmblock " /etc/mtab; then
       # if it's mounted, then unmount it
       vmware_exec_selinux "umount $vmblockmntpt"
    fi

    # Unload the kernel module
    vmware_unload_module $vmblock
}

# This is necessary to allow udev time to create a device node.  If we don't
# wait then udev will override the permissions we choose when it creates the
# device node after us.
vmware_delay_for_node() {
   local node="$1"
   local delay="$2"

   while [ ! -e $node -a ${delay} -gt 0 ]; do
      delay=`expr $delay - 1`
      sleep 1
   done
}

vmware_real_modname() {
   # modprobe might be old and not understand the --resolve-alias option, or
   # there might not be an alias. In both cases we assume
   # that the module is not upstreamed.
   mod=$1
   mod_alias=$2

   modname=$(/sbin/modprobe --resolve-alias ${mod_alias} 2>/dev/null)
   if [ $? = 0 -a "$modname" != "" ] ; then
        echo $modname
   else
        echo $mod
   fi
}

vmware_is_upstream() {
   modname=$1
   vmware_exec_selinux "$vmdb_answer_LIBDIR/sbin/vmware-modconfig-console \
                           --install-status" | grep -q "${modname}: other"
   if [ $? = 0 ]; then
      echo "yes"
   else
      echo 'no'
   fi
}

# starts after vmci is loaded
vmware_start_vsock() {
  real_vmci=$(vmware_real_modname $vmci $vmci_alias)

  if [ "`isLoaded "$real_vmci"`" = 'no' ]; then
    # vsock depends on vmci
    return 1
  fi

  real_vsock=$(vmware_real_modname $vsock $vsock_alias)

  vmware_load_module $real_vsock
  vmware_rm_stale_node vsock
  # Give udev 5 seconds to create our node
  vmware_delay_for_node "/dev/vsock" 5
  if [ ! -e /dev/vsock ]; then
     local minor=`cat /proc/misc | grep vsock | awk '{print $1}'`
     mknod --mode=666 /dev/vsock c 10 "$minor"
  else
     chmod 666 /dev/vsock
  fi

  return 0
}

# unloads before vmci
vmware_stop_vsock() {
  # Nothing to do if module is upstream
  if [ "`vmware_is_upstream $vsock`" = 'yes' ]; then
    return 0
  fi

  real_vsock=$(vmware_real_modname $vsock $vsock_alias)
  vmware_unload_module $real_vsock
  rm -f /dev/vsock
}

is_ESX_running() {
  if [ ! -f "$vmdb_answer_SBINDIR"/vmware-checkvm ] ; then
    echo no
    return
  fi
  if "$vmdb_answer_SBINDIR"/vmware-checkvm -p | grep -q ESX; then
    echo yes
  else
    echo no
  fi
}

#
# Start vmblock only if ESX is not running and the config script
# built/loaded it (kernel is >= 2.4.0 and  product is tools-for-linux).
# Also don't start when in open-vm compat mode
#
is_vmblock_needed() {
  if [ "`is_ESX_running`" = 'yes' -o "$vmdb_answer_OPEN_VM_COMPAT" = 'yes' ]; then
    echo no
  else
    if [ "$vmdb_answer_VMBLOCK_CONFED" = 'yes' ]; then
      echo yes
    else
      echo no
    fi
  fi
}

VMUSR_PATTERN="(vmtoolsd.*vmusr|vmware-user)"

vmware_signal_vmware_user() {
# Signal all running instances of the user daemon.
# Our pattern ensures that we won't touch the system daemon.
   pkill -$1 -f "$VMUSR_PATTERN"
   return 0
}

# A USR1 causes vmware-user to release any references to vmblock or
# /proc/fs/vmblock/mountPoint, allowing vmblock to unload, but vmware-user
# to continue running. This preserves the user context vmware-user is
# running within.
vmware_unblock_vmware_user() {
  vmware_signal_vmware_user 'USR1'
}

# A USR2 causes vmware-user to relaunch itself, picking up vmblock anew.
# This preserves the user context vmware-user is running within.
vmware_restart_vmware_user() {
  vmware_signal_vmware_user 'USR2'
}

# Checks if there an instance of vmware-user process exists in the system.
is_vmware_user_running() {
  if pgrep -f "$VMUSR_PATTERN" > /dev/null 2>&1; then
    echo yes
  else
    echo no
  fi
}

wrap () {
  AMSG="$1"
  while [ `echo $AMSG | wc -c` -gt 75 ] ; do
    AMSG1=`echo $AMSG | sed -e 's/\(.\{1,75\} \).*/\1/' -e 's/  [ 	]*/  /'`
    AMSG=`echo $AMSG | sed -e 's/.\{1,75\} //' -e 's/  [ 	]*/  /'`
    echo "  $AMSG1"
  done
  echo "  $AMSG"
  echo " "
}

#---------------------------------------------------------------------------
#
# load_settings
#
# Load VMware Installer Service settings
#
# Returns:
#    0 on success, otherwise 1.
#
# Side Effects:
#    vmdb_* variables are set.
#---------------------------------------------------------------------------

load_settings() {
  local settings=`$DATABASE/vmis-settings`
  if [ $? -eq 0 ]; then
    eval "$settings"
    return 0
  else
    return 1
  fi
}

#---------------------------------------------------------------------------
#
# launch_binary
#
# Launch a binary with resolved dependencies.
#
# Returns:
#    None.
#
# Side Effects:
#    Process is replaced with the binary if successful,
#    otherwise returns 1.
#---------------------------------------------------------------------------

launch_binary() {
  local component="$1"		# IN: component name
  shift
  local binary="$2"		# IN: binary name
  shift
  local args="$@"		# IN: arguments
  shift

  # Convert -'s in component name to _ and lookup its libdir
  local component=`echo $component | tr '-' '_'`
  local libdir="vmdb_$component_libdir"

  exec "$libdir"'/bin/launcher.sh'		\
       "$libdir"'/lib'				\
       "$libdir"'/bin/'"$binary"		\
       "$libdir"'/libconf' "$args"
  return 1
}
# END_OF_UTIL_DOT_SH

vmware_etc_dir=/etc/vmware

# Since this script is installed, our main database should be installed too and
# should contain the basic information
vmware_db="$vmware_etc_dir"/locations
if [ ! -r "$vmware_db" ]; then
   echo 'Warning: Unable to find '"`vmware_product_name`""'"'s main database '"$vmware_db"'.'
   echo

   exit 1
fi

# BEGINNING_OF_DB_DOT_SH
#!/bin/sh

#
# Manage an installer database
#

# Add an answer to a database in memory
db_answer_add() {
  local dbvar="$1" # IN/OUT
  local id="$2"    # IN
  local value="$3" # IN
  local answers
  local i

  eval "$dbvar"'_answer_'"$id"'="$value"'

  eval 'answers="$'"$dbvar"'_answers"'
  # There is no double quote around $answers on purpose
  for i in $answers; do
    if [ "$i" = "$id" ]; then
      return
    fi
  done
  answers="$answers"' '"$id"
  eval "$dbvar"'_answers="$answers"'
}

# Remove an answer from a database in memory
db_answer_remove() {
  local dbvar="$1" # IN/OUT
  local id="$2"    # IN
  local new_answers
  local answers
  local i

  eval 'unset '"$dbvar"'_answer_'"$id"

  new_answers=''
  eval 'answers="$'"$dbvar"'_answers"'
  # There is no double quote around $answers on purpose
  for i in $answers; do
    if [ "$i" != "$id" ]; then
      new_answers="$new_answers"' '"$i"
    fi
  done
  eval "$dbvar"'_answers="$new_answers"'
}

# Load all answers from a database on stdin to memory (<dbvar>_answer_*
# variables)
db_load_from_stdin() {
  local dbvar="$1" # OUT

  eval "$dbvar"'_answers=""'

  # read doesn't support -r on FreeBSD 3.x. For this reason, the following line
  # is patched to remove the -r in case of FreeBSD tools build. So don't make
  # changes to it.
  while read -r action p1 p2; do
    if [ "$action" = 'answer' ]; then
      db_answer_add "$dbvar" "$p1" "$p2"
    elif [ "$action" = 'remove_answer' ]; then
      db_answer_remove "$dbvar" "$p1"
    fi
  done
}

# Load all answers from a database on disk to memory (<dbvar>_answer_*
# variables)
db_load() {
  local dbvar="$1"  # OUT
  local dbfile="$2" # IN

  db_load_from_stdin "$dbvar" < "$dbfile"
}

# Iterate through all answers in a database in memory, calling <func> with
# id/value pairs and the remaining arguments to this function
db_iterate() {
  local dbvar="$1" # IN
  local func="$2"  # IN
  shift 2
  local answers
  local i
  local value

  eval 'answers="$'"$dbvar"'_answers"'
  # There is no double quote around $answers on purpose
  for i in $answers; do
    eval 'value="$'"$dbvar"'_answer_'"$i"'"'
    "$func" "$i" "$value" "$@"
  done
}

# If it exists in memory, remove an answer from a database (disk and memory)
db_remove_answer() {
  local dbvar="$1"  # IN/OUT
  local dbfile="$2" # IN
  local id="$3"     # IN
  local answers
  local i

  eval 'answers="$'"$dbvar"'_answers"'
  # There is no double quote around $answers on purpose
  for i in $answers; do
    if [ "$i" = "$id" ]; then
      echo 'remove_answer '"$id" >> "$dbfile"
      db_answer_remove "$dbvar" "$id"
      return
    fi
  done
}

# Add an answer to a database (disk and memory)
db_add_answer() {
  local dbvar="$1"  # IN/OUT
  local dbfile="$2" # IN
  local id="$3"     # IN
  local value="$4"  # IN

  db_remove_answer "$dbvar" "$dbfile" "$id"
  echo 'answer '"$id"' '"$value" >> "$dbfile"
  db_answer_add "$dbvar" "$id" "$value"
}

# Add a file to a database on disk
# 'file' is the file to put in the database (it may not exist on the disk)
# 'tsfile' is the file to get the timestamp from, '' if no timestamp
db_add_file() {
  local dbfile="$1" # IN
  local file="$2"   # IN
  local tsfile="$3" # IN
  local date

  if [ "$tsfile" = '' ]; then
    echo 'file '"$file" >> "$dbfile"
  else
    date=`date -r "$tsfile" '+%s' 2> /dev/null`
    if [ "$date" != '' ]; then
      date=' '"$date"
    fi
    echo 'file '"$file$date" >> "$dbfile"
  fi
}

# Remove file from database
db_remove_file() {
  local dbfile="$1" # IN
  local file="$2"   # IN

  echo "remove_file $file" >> "$dbfile"
}

# Add a directory to a database on disk
db_add_dir() {
  local dbfile="$1" # IN
  local dir="$2"    # IN

  echo 'directory '"$dir" >> "$dbfile"
}
# END_OF_DB_DOT_SH

db_load 'vmdb' "$vmware_db"

VNETLIB_LOG=/var/log/vnetlib

# This comment is a hack to prevent RedHat distributions from outputing
# "Starting <basename of this script>" when running this startup script.
# We just need to write the word daemon followed by a space

# This defines echo_success() and echo_failure() on RedHat
if [ -r "$vmdb_answer_INITSCRIPTSDIR"'/functions' ]; then
   . "$vmdb_answer_INITSCRIPTSDIR"'/functions'
fi

# This defines $rc_done and $rc_failed on S.u.S.E.
if [ -f /etc/rc.config ]; then
   # Don't include the entire file: there could be conflicts
   rc_done=`(. /etc/rc.config; echo "$rc_done")`
   rc_failed=`(. /etc/rc.config; echo "$rc_failed")`
else
   # Make sure the ESC byte is literal: Ash does not support echo -e
   rc_done='[71G done'
   rc_failed='[71Gfailed'
fi

subsys=vmware
driver=vmmon
vnet=vmnet
vmblock=vmblock
vmci=vmci
vsock=vsock

# SHM settings
shmmaxPath=/proc/sys/kernel/shmmax
shmmaxMinValue=268435456 # 256MB

# Web Access configuration
webAccess="${vmdb_answer_LIBDIR}/webAccess/java/@@JRE_DIST@@/bin/webAccess"
watchdog="${vmdb_answer_BINDIR}/vmware-watchdog"
webAccessServiceName="VMware Virtual Infrastructure Web Access"
CATALINA_HOME="${vmdb_answer_LIBDIR}/webAccess/tomcat/@@TOMCAT_DIST@@"
webAccessOpts="-client -Xmx64m -XX:MinHeapFreeRatio=30 -XX:MaxHeapFreeRatio=30 -Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager -Djava.endorsed.dirs=$CATALINA_HOME/common/endorsed -classpath $CATALINA_HOME/bin/bootstrap.jar:$CATALINA_HOME/bin/commons-logging-api.jar -Dcatalina.base=$CATALINA_HOME -Dcatalina.home=$CATALINA_HOME -Djava.io.tmpdir=$CATALINA_HOME/temp org.apache.catalina.startup.Bootstrap"

#
# Utilities
#

# BEGINNING_OF_IPV4_DOT_SH
#!/bin/sh

#
# IPv4 address functions
#
# Thanks to Owen DeLong <owen@delong.com> for pointing me at bash's arithmetic
# expansion ability, which is a lot faster than using 'expr'
#

# Compute the subnet address associated to a couple IP/netmask
ipv4_subnet() {
  local ip="$1"
  local netmask="$2"

  # Split quad-dotted addresses into bytes
  # There is no double quote around the back-quoted expression on purpose
  # There is no double quote around $ip and $netmask on purpose
  set -- `IFS='.'; echo $ip $netmask`

  echo $(($1 & $5)).$(($2 & $6)).$(($3 & $7)).$(($4 & $8))
}

# Compute the broadcast address associated to a couple IP/netmask
ipv4_broadcast() {
  local ip="$1"
  local netmask="$2"

  # Split quad-dotted addresses into bytes
  # There is no double quote around the back-quoted expression on purpose
  # There is no double quote around $ip and $netmask on purpose
  set -- `IFS='.'; echo $ip $netmask`

  echo $(($1 | (255 - $5))).$(($2 | (255 - $6))).$(($3 | (255 - $7))).$(($4 | (255 - $8)))
}
# END_OF_IPV4_DOT_SH

# Are we running in a VM?
vmware_inVM() {
   "$vmware_etc_dir"/checkvm >/dev/null 2>&1
}

#
# Report a positive number if there are any VMs running.
# May not be the actual vmmon reference count.
#
vmmonUseCount() {
   local count
   # Beware of module dependencies here. An exact match is important
   count=`/sbin/lsmod | awk 'BEGIN {n = 0} {if ($1 == "'"$driver"'") n = $3} END {print n}'`
   # If CONFIG_MODULE_UNLOAD is not set in the kernel, lsmod prints '-' instead of the
   # reference count, so ask vmrun, or if we don't have vmrun, look for running vmx processes
   if [ x${count} = "x-" ]
   then 
      type vmrun > /dev/null 2>&1
      if [ $? -eq 0 ]
      then
         count=`vmrun list | awk 'BEGIN {n=0} /^Total running VMs:/ {n = $4} END {print n}'`
      else
         count=`ps -afe | grep "/bin/vmware-vmx" | grep -v grep | wc -l`
      fi
   fi
   echo $count
}

# Is a given module loaded?
isLoaded() {
   local module="$1"

   /sbin/lsmod | awk 'BEGIN {n = "no";} {if ($1 == "'"$module"'") n = "yes";} END {print n;}'
}

# Build a Linux kernel integer version
kernel_version_integer() {
   echo $(((($1 * 256) + $2) * 256 + $3))
}

# Get the running kernel integer version
get_version_integer() {
   local version_uts
   local v1
   local v2
   local v3

   version_uts=`uname -r`

   # There is no double quote around the back-quoted expression on purpose
   # There is no double quote around $version_uts on purpose
   set -- `IFS='.'; echo $version_uts`
   v1="$1"
   v2="$2"
   v3="$3"
   # There is no double quote around the back-quoted expression on purpose
   # There is no double quote around $v3 on purpose
   set -- `IFS='-+ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz'; echo $v3`
   v3="$1"

   kernel_version_integer "$v1" "$v2" "$v3"
}

# Execute a command via the vimsh utility
vmware_run_vimsh_cmd() {
   local msg="$1"
   local cmd="$2"
   local authdPort="$vmdb_answer_AUTHDPORT"

   vmware_exec "$msg" "$vmdb_answer_BINDIR/vmware-vimsh" -r -n -e \
       '"hostsvc/connect localhost '$authdPort'; hostsvc/login; '$cmd'"'
}

vmware_load_module() {
   /sbin/insmod -s -f "/lib/modules/`uname -r`/misc/$1.o" || exit 1
   return 0
}

vmware_unload_module() {
   if [ "`isLoaded "$1"`" = 'yes' ]; then
      /sbin/rmmod "$1" || exit 1
   fi
   return 0
}

# Start the virtual machine monitor kernel service
vmware_start_vmmon() {
   vmware_load_module $driver
}

# Stop the virtual machine monitor kernel service
vmware_stop_vmmon() {
   vmware_unload_module $driver
}

# Start the virtual ethernet kernel service
vmware_start_vmnet() {
   vmware_load_module $vnet
}

# Stop the virtual ethernet kernel service
vmware_stop_vmnet() {
   vmware_unload_module $vnet
}

# Start the virtual machine communication interface kernel service
vmware_start_vmci() {
   # only load vmci if it's not already loaded
   if [ "`isLoaded "$vmci"`" = 'no' ]; then
      vmware_load_module "$vmci"
   fi
   vmware_rm_stale_node vmci
   if [ ! -e /dev/vmci ]; then
      local minor=`cat /proc/misc | grep vmci | awk '{print $1}'`
      mknod --mode=666 /dev/vmci c 10 "$minor"
   else
      chmod 666 /dev/vmci
   fi

   return 0
}

# Stop the virtual machine communication interface kernel service
vmware_stop_vmci() {
   # only unload vmci if it's already loaded
   if [ "`isLoaded "$vmci"`" = 'yes' ]; then
     vmware_unload_module "$vmci"
   fi
   rm -f /dev/vmci
}

is_vsock_needed() {
   if [ "$vmdb_answer_VSOCK_CONFED" = 'yes' ]; then
      echo yes
   else
      echo no
   fi
}

# Start host agent
vmware_start_hostd() {
   vmware_bg_exec "`vmware_product_name` Host Agent" \
      "$vmdb_answer_SBINDIR/vmware-hostd" -a -d -u "$vmware_etc_dir/hostd/config.xml"
}

# autostart VMs
vmware_autostart_vms() {
   vmware_run_vimsh_cmd 'Virtual machines' 'hostsvc/autostartmanager/autostart'
}

# autostop VMs
vmware_autostop_vms() {
   vmware_run_vimsh_cmd 'Virtual machines' 'hostsvc/autostartmanager/autostop'
}

# Stop host agent
vmware_stop_hostd() {
   # Stop Host Agent
   vmware_run_vimsh_cmd "`vmware_product_name` Host Agent" 'internalsvc/shutdown'
}

vmware_start_webAccess() {
  echo -n '   '"$webAccessServiceName"
  $watchdog -s webAccess -u 30 -q 5 "$webAccess $webAccessOpts start" > /dev/null 2>&1 &
}

vmware_stop_webAccess() {
  # Shut down the webAccess watchdog
  $watchdog -k webAccess > /dev/null 2>&1

  echo -n '   '"$webAccessServiceName"

  # Shut down webAccess itself
  $webAccess $webAccessOpts stop > /dev/null 2>&1
  killall webAccess > /dev/null 2>&1
}

vmware_start_authdlauncher() {
   vmware_bg_exec "`vmware_product_name` Authentication Daemon" \
      "$vmdb_answer_SBINDIR/vmware-authdlauncher"
}

vmware_stop_authdlauncher() {
   local launcherpid=`pidof vmware-authdlauncher`
   if [ -n "$launcherpid" ]; then
      vmware_synchrone_kill $launcherpid "TERM"
   fi
}

# Make sure the system has enough shared memory available to cover shmmaxMinValue.
# To handle overflow/wrapping, check that shmmax is greater than 1 since any overflow
# will make shmmax look negative.  At least until shmmax or shmmaxMinValue wrap around
# again.
vmware_check_shared_memory() {
   if [ -f "$shmmaxPath" ]; then
      shmmax=`cat $shmmaxPath`
      # Account for numbers that are too large that they wrap around and alias
      # to a smaller number or they are outright set to -1.  If "1 < XXXX" fails
      # then the XXX value is # out of bounds.  The only acceptable combo is that
      # both values satisfy that condition, else report that the max value the
      # system supports may not satisfy this programs requirements.
      if  ((  $shmmax < 1 )) || (( $shmmaxMinValue < 1 )) \
       || (( $shmmax < $shmmaxMinValue )) ; then
         echo "$shmmaxMinValue" > "$shmmaxPath"
         echo ""
         echo "Setting the max shared memory the system will allow to $shmmaxMinValue."
         echo ""
      fi
   fi
   return 0
}

is_vmci_needed() {
   if [ "$vmdb_answer_VMCI_CONFED" = 'yes' ]; then
      echo yes
   else
      echo no
   fi
}

check_configured() {
   if [ -e "$vmware_etc_dir"/not_configured ]; then
      echo "`vmware_product_name`"' is installed, but it has not been (correctly) configured'
      echo 'for the running kernel. To (re-)configure it, invoke the'
      echo 'following command: '"$vmdb_answer_BINDIR"'/vmware-config.pl.'
      echo

      exit 1
   fi
}

service_vmware() {
   # See how we were called.
   case "$1" in
      start)
         if vmware_inVM; then
            # Refuse to start services in a VM: they are useless
            exit 1
         fi

         echo 'Starting VMware services:'
         exitcode='0'

         vmware_exec 'Virtual machine monitor' vmware_start_vmmon
         exitcode=$(($exitcode + $?))

         if [ "`is_vmci_needed`" = 'yes' ]; then
            vmware_exec 'Virtual machine communication interface' vmware_start_vmci
            exitcode=$(($exitcode + $?))
         fi

         # vsock needs vmci started first
         if [ "`is_vsock_needed`" = 'yes' ]; then
            vmware_exec 'VM communication interface socket family:' vmware_start_vsock
            # a vsock failure to load shouldn't cause the init to fail completely.
         fi

         if [ "`is_vmblock_needed`" = 'yes' ] ; then
            vmware_exec 'Blocking file system' vmware_start_vmblock
            exitcode=$(($exitcode + $?))
         fi

         # Try to load parport_pc. Failure does not matter.
         /sbin/modprobe parport_pc >/dev/null 2>&1

         if [ "$vmdb_answer_NETWORKING" = 'yes' ]; then
            vmware_exec 'Virtual ethernet' vmware_start_vmnet
            exitcode=$(($exitcode + $?))

            if [ "`vmware_product`" = "ws" ]; then
	      "$vmdb_answer_BINDIR"/vmware-networks --start >> $VNETLIB_LOG 2>&1
	    else
	      "$vmdb_answer_LIBDIR"/net-services.sh start
              exitcode=$(($exitcode + $?))
	    fi
         fi

         if [ "$exitcode" -gt 0 -a `vmware_product` != "ws" ]; then
            # Set the 'not configured' flag
            touch "$vmware_etc_dir"'/not_configured'
            chmod 644 "$vmware_etc_dir"'/not_configured'
            db_add_file "$vmware_db" "$vmware_etc_dir"'/not_configured' \
               "$vmware_etc_dir"'/not_configured'
            exit 1
         fi

         if [ "$vmdb_answer_VMAUTHD_USE_LAUNCHER" = 'yes' ]; then
            vmware_start_authdlauncher
         fi

         [ -d /var/lock/subsys ] || mkdir -p /var/lock/subsys
         touch /var/lock/subsys/"$subsys"

         vmware_exec "Shared Memory Available"  vmware_check_shared_memory
      ;;

      stop)
         echo 'Stopping VMware services:'
         exitcode='0'

         vmware_exec 'VMware Authentication Daemon' vmware_stop_authdlauncher

         # If the 'K' version of this script is running, the system is
         # stoping services not because the user is running vmware-config.pl
         # or running the initscript directly but because the user wants to
         # shutdown.  Suspend all VMs.
         if [ "`echo $BASENAME | sed -ne '/^K[0-9].vmware/p'`" ] ; then
            if [ -x "$vmdb_answer_BINDIR"/vmrun ] ; then
               for i in `pidof vmware-vmx` ; do
                  "$vmdb_answer_BINDIR"/vmrun suspend `ps -p $i -f | \
                       sed -ne '/vmware/s/.* \(\/.*\.vmx\)/\1/p'` 2> /dev/null
               done
            fi

         fi

         if [ "`vmmonUseCount`" -gt 0 ]; then
            echo " " >&2
            echo 'At least one instance of '"`vmware_product_name`"' is still running.' 1>&2
            echo 'Please stop all running instances of '"`vmware_product_name`"' first.' 1>&2
            echo " " >&2

            # Since we stopped authdlauncer to prevent new connections before disabling
            # any vmxs, need to restart it here to restore the environment back to
            # what it was before this init script ran.
            vmware_exec 'VMware Authentication Daemon' vmware_start_authdlauncher

            # The unconfigurator handle this exit code differently
            exit 2
         fi

         # vmci is used by vsock so the module can't unload until vsock does.
         if [ "`is_vsock_needed`" = 'yes' ]; then
            vmware_exec 'VM communication interface socket family:' vmware_stop_vsock
            exitcode=$(($exitcode + $?))
         fi

         if [ "`is_vmci_needed`" = 'yes' ]; then
            vmware_exec 'Virtual machine communication interface' vmware_stop_vmci
            exitcode=$(($exitcode + $?))
         fi

         vmware_exec 'Virtual machine monitor' vmware_stop_vmmon
         exitcode=$(($exitcode + $?))

         if [ "`is_vmblock_needed`" = 'yes' ] ; then
            vmware_exec 'Blocking file system' vmware_stop_vmblock
            exitcode=$(($exitcode + $?))
         fi

         # Try to unload parport_pc. Failure does not matter, maybe
         # it is in use.  Or maybe we should not mess with it at all?
         /sbin/modprobe -r parport_pc >/dev/null 2>&1

         if [ "$vmdb_answer_NETWORKING" = "yes" ]; then
            # NB: must kill off processes using vmnet before
            #     unloading module
            if [ "`vmware_product`" = "ws" ]; then
	      "$vmdb_answer_BINDIR"/vmware-networks --stop >> $VNETLIB_LOG 2>&1
	    else
              "$vmdb_answer_LIBDIR"/net-services.sh stop
              exitcode=$(($exitcode + $?))
	    fi

            vmware_exec 'Virtual ethernet' vmware_stop_vmnet
            exitcode=$(($exitcode + $?))
         fi

         # The vmware and vmware-tray processes don't terminate automatically
         # when the other services are shutdown.  They persist after calling
         # 'init.d/vmware stop' and will happily keep going through an init
         # start command, continuing to minimally function, blissfully ignorant.
         # Time for a buzzkill.
         for i in `pidof vmware vmware-tray` ; do
            vmware_synchrone_kill $i "INT"
         done

         if [ "$exitcode" -gt 0 ]; then
            exit 1
         fi

         rm -f /var/lock/subsys/"$subsys"
      ;;

      status)
         if [ "`vmmonUseCount`" -gt 0 ]; then
            echo 'At least one instance of '"`vmware_product_name`"' is still running.'
            echo
            if [ "$2" = "vmcount" ]; then
               exit 2
            fi
         fi
         if [ "$2" = "vmcount" ]; then
            exit 0
         fi

         exitcode='0'

         if [ "`vmware_product`" = "ws" ]; then
	   "$vmdb_answer_BINDIR"/vmware-networks --status >> $VNETLIB_LOG 2>&1
	 else
           "$vmdb_answer_LIBDIR"/net-services.sh status
           exitcode=$(($exitcode + $?))
	 fi

         echo -n "Module $driver "
         [ "`isLoaded "$driver"`" = 'yes' ] && echo loaded || echo "not loaded"
         if [ "$vmdb_answer_NETWORKING" = "yes" ]; then
            echo -n "Module $vnet "
            [ "`isLoaded "$vnet"`" = 'yes' ] && echo loaded || echo "not loaded"
         fi

         if [ "$exitcode" -gt 0 ]; then
            exit 1
         fi
      ;;

      restart)
         "$SCRIPTNAME" stop && "$SCRIPTNAME" start
      ;;

      *)
         echo "Usage: "$BASENAME" {start|stop|status|restart}"
         exit 1
   esac
}

service_vmware_mgmt() {
   # See how we were called.
   case "$1" in
      start)
         if [ "`vmware_product`" = "wgs" ]; then
            echo 'Starting VMware management services:'
            vmware_start_hostd
            vmware_start_webAccess
            #clean up output from webAccess
            echo
         fi
      ;;
      stop)
         if [ "`vmware_product`" = "wgs" ]; then
            echo 'Stopping VMware management services:'
            vmware_stop_webAccess
            #clean up output from webAccess
            echo
            vmware_stop_hostd
         fi
      ;;
      restart)
         "$SCRIPTNAME" stop && "$SCRIPTNAME" start
      ;;
      *)
         echo "Usage: "$BASENAME" {start|stop|restart}"
         exit 1
      ;;
   esac
}

service_vmware_autostart() {
   # See how we were called.
   case "$1" in
      start)
         if [ "`vmware_product`" = "wgs" ]; then
            echo 'Starting VMware autostart virtual machines:'
            vmware_autostart_vms # might no-op if after first hostd invocation
         fi
      ;;
      stop)
         if [ "`vmware_product`" = "wgs" ]; then
            echo 'Stopping VMware autostart virtual machines:'
            vmware_autostop_vms
         fi
      ;;
      restart)
         "$SCRIPTNAME" stop && "$SCRIPTNAME" start
      ;;
      *)
         echo "Usage: "$BASENAME" {start|stop|restart}"
         exit 1
      ;;
   esac
}

SCRIPTNAME="$0"
BASENAME=`basename "$SCRIPTNAME"`

# Check permissions
if [ "`id -ur`" != '0' ]; then
   echo 'Error: you must be root.'
   echo
   exit 1
fi

if [ "$1" = "start" ]; then
   check_configured
fi

case "$BASENAME" in
   vmware-core)
      service_vmware "$1"
   ;;

   vmware-mgmt)
      service_vmware_mgmt "$1"
   ;;

   vmware-autostart)
      service_vmware_autostart "$1"
   ;;

   *)
      case $1 in
         start)
            service_vmware "$1"
            service_vmware_mgmt "$1"
            service_vmware_autostart "$1"
         ;;
         stop)
            service_vmware_autostart "$1"
            service_vmware_mgmt "$1"
            service_vmware "$1"
            status=$?
            # The preun script in rpm calls this file and needs the
            # error return value in case there are running vmxs left.
            if [ $status -ne 0 ]; then
              exit $status
            fi
         ;;
         *)
            service_vmware "$@" # service_vmware will handle status and restart properly, as well as usage
         ;;
      esac
   ;;
esac

exit 0

