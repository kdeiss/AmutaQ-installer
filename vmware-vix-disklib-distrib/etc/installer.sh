#!/bin/sh
# Tar installer object
#
# This file is saved on the disk when the .tar package is installed by
# vmware-install.pl. It can be invoked by any installer.

#
# Tools
#

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

#
# Implementation of the methods
#

# Return the human-readable type of the installer
installer_kind() {
  echo 'tar'

  exit 0
}

# Return the human-readable version of the installer
installer_version() {
  echo '4'

  exit 0
}

# Return the specific VMware product
vmware_product() {
  echo 'vix-disklib'

  exit 0
}

# Set the name of the main /etc/vmware* directory
# Set up variables depending on the main RegistryDir
initialize_globals() {
  if [ "`vmware_product`" = 'console' ]; then
    gRegistryDir='/etc/vmware-console'
    gUninstaller='vmware-uninstall-console.pl'
  elif [ "`vmware_product`" = 'api' ]; then
    gRegistryDir='/etc/vmware-api'
    gUninstaller='vmware-uninstall-api.pl'
  elif [ "`vmware_product`" = 'mui' ]; then
    gRegistryDir='/etc/vmware-mui'
    gUninstaller='vmware-uninstall-mui.pl'
  elif [ "`vmware_product`" = 'tools-for-linux' ]; then
    gRegistryDir='/etc/vmware-tools'
    gUninstaller='vmware-uninstall-tools.pl'
  elif [ "`vmware_product`" = 'tools-for-freebsd' ]; then
    gRegistryDir='/etc/vmware-tools'
    gUninstaller='vmware-uninstall-tools.pl'
  elif [ "`vmware_product`" = 'tools-for-solaris' ]; then
    gRegistryDir='/etc/vmware-tools'
    gUninstaller='vmware-uninstall-tools.pl'
  elif [ "`vmware_product`" = 'vix' ]; then
    gRegistryDir='/etc/vmware-vix'
    gUninstaller='vmware-uninstall-vix.pl'
  elif [ "`vmware_product`" = 'vix-disklib' ]; then
    gRegistryDir='/etc/vmware-vix-disklib'
    gUninstaller='vmware-uninstall-vix-disklib.pl'
  elif [ "`vmware_product`" = 'viperl' ]; then
    gRegistryDir='/etc/vmware-viperl'
    gUninstaller='vmware-uninstall-viperl.pl'
  elif [ "`vmware_product`" = 'vicli' ]; then
    gRegistryDir='/etc/vmware-vcli'
    gUninstaller='vmware-uninstall-vSphere-CLI.pl'
  elif [ "`vmware_product`" = 'nvdk' ]; then
    gRegistryDir='/etc/vmware-nvdk'
    gUninstaller='vmware-uninstall-nvdk.pl'
  else
    gRegistryDir='/etc/vmware'
    gUninstaller='vmware-uninstall.pl'
  fi
  gInstallerMainDB="$gRegistryDir"'/locations'
}

# Convert the installer database format to formats used by older installers
# The output should be a .tar.gz containing enough information to allow a
# clean "upgrade" (which will actually be a downgrade) by an older installer
installer_convertdb() {
  local format="$1"
  local output="$2"
  local tmpdir

  case "$format" in
    rpm4|tar4)
      if [ "$format" = 'tar4' ]; then
        echo 'Keeping the tar4 installer database format.'
      else
        echo 'Converting the tar4 installer database format'
        echo '        to the rpm4 installer database format.'
      fi
      echo
      # The next installer uses the same database format. Backup a full
      # database state that it can use as a fresh new database.
      #
      # Everything should go in:
      #  /etc/vmware*/
      #              state/
      #
      # But those directories do not have to be referenced,
      # the next installer will do it just after restoring the backup
      # because only it knows if those directories have been created.
      #
      # Also, do not include those directories in the backup, because some
      # versions of tar (1.13.17+ are ok) do not untar directory permissions
      # as described in their documentation.
      make_tmp_dir 'tmpdir' 'vmware-installer'
      mkdir -p "$tmpdir""$gRegistryDir"
      db_add_file "$tmpdir""$gInstallerMainDB" "$gInstallerMainDB" ''
      db_load 'db' "$gInstallerMainDB"
      write() {
        local id="$1"
        local value="$2"
        local dbfile="$3"

        # No database conversions are necessary

        echo 'answer '"$id"' '"$value" >> "$dbfile"
      }
      db_iterate 'db' 'write' "$tmpdir""$gInstallerMainDB"
      files='./'"$gInstallerMainDB"
      
      # The Bourne shell (Solaris' default) doesn't support -e so use -f
      # instead.  We only need to worry about this for tar4 and tar3 since the
      # Solaris Tools did not exist before the tar3 database version was
      # created.
      configExists='no'
      if [ "`vmware_product`" = 'tools-for-solaris' ]; then
         if [ -f "$gRegistryDir"/config ]; then
            configExists='yes'
         fi
      elif [ -e "$gRegistryDir"/config ]; then
         configExists='yes'
      fi
      if [ "$configExists" = 'yes' ]; then
         mkdir -p "$tmpdir""$gRegistryDir"'/state'
         cp "$gRegistryDir"/config "$tmpdir""$gRegistryDir"'/state/config'
         db_add_file "$tmpdir""$gInstallerMainDB" "$gRegistryDir"'/state/config' "$tmpdir""$gRegistryDir"'/state/config'
         files="$files"' .'"$gRegistryDir"'/state/config'
      fi
      # There is no double quote around $files on purpose
      if [ "`vmware_product`" = 'tools-for-solaris' ]; then
         # Solaris' tar(1) does not support gnu tar's -C and -z options.
         origDir=`pwd`
         cd "$tmpdir" && tar -copf - $files | gzip > "$output"
         cd $origDir
      else
         tar -C "$tmpdir" -czopf "$output" $files 2> /dev/null
      fi
      rm -rf "$tmpdir"

      exit 0;
      ;;
    rpm3|tar3)
      echo 'Converting the tar4 installer database format'
      echo '        to the '"$format"' installer database format.'
      echo
      # The next installer uses the same database format. Backup a full
      # database state that it can use as a fresh new database.
      #
      # Everything should go in:
      #  /etc/vmware*/
      #              state/
      #
      # But those directories do not have to be referenced,
      # the next installer will do it just after restoring the backup
      # because only it knows if those directories have been created.
      #
      # Also, do not include those directories in the backup, because some
      # versions of tar (1.13.17+ are ok) do not untar directory permissions
      # as described in their documentation.
      make_tmp_dir 'tmpdir' 'vmware-installer'
      mkdir -p "$tmpdir""$gRegistryDir"
      db_add_file "$tmpdir""$gInstallerMainDB" "$gInstallerMainDB" ''
      db_load 'db' "$gInstallerMainDB"
      write() {
        local id="$1"
        local value="$2"
        local dbfile="$3"

        # The tar4|rpm4 added two keywords that are not supported by earlier
        # installers.   These are removed here so that they don't propagate
        # back through on a subsequent upgrade (with perhaps no longer correct
        # values)
        #
        #    VNET_n_DHCP            -> <nothing>
        #    VNET_n_HOSTONLY_SUBNET -> <nothing>
        #
        if echo $id | grep 'VNET_[[:digit:]]\+_DHCP' &>/dev/null; then
           return;
        elif echo $id | grep 'VNET_[[:digit:]]\+_HOSTONLY_SUBNET' &>/dev/null; then
           return;
        fi

        echo 'answer '"$id"' '"$value" >> "$dbfile"
      }
      db_iterate 'db' 'write' "$tmpdir""$gInstallerMainDB"
      files='./'"$gInstallerMainDB"
      
      # The Bourne shell (Solaris' default) doesn't support -e so use -f
      # instead.  We only need to worry about this for tar4 and tar3 since the
      # Solaris Tools did not exist before the tar3 database version was
      # created.
      configExists='no'
      if [ "`vmware_product`" = 'tools-for-solaris' ]; then
         if [ -f "$gRegistryDir"/config ]; then
            configExists='yes'
         fi
      elif [ -e "$gRegistryDir"/config ]; then
         configExists='yes'
      fi
      if [ "$configExists" = 'yes' ]; then
        mkdir -p "$tmpdir""$gRegistryDir"'/state'
        cp "$gRegistryDir"/config "$tmpdir""$gRegistryDir"'/state/config'
        db_add_file "$tmpdir""$gInstallerMainDB" "$gRegistryDir"'/state/config' "$tmpdir""$gRegistryDir"'/state/config'
        files="$files"' .'"$gRegistryDir"'/state/config'
      fi
      # There is no double quote around $files on purpose
      if [ "`vmware_product`" = 'tools-for-solaris' ]; then
         # Solaris' tar(1) does not support gnu tar's -C and -z options.
         origDir=`pwd`
         cd "$tmpdir" && tar -copf - $files | gzip > "$output"
         cd $origDir
      else
         tar -C "$tmpdir" -czopf "$output" $files 2> /dev/null
      fi
      rm -rf "$tmpdir"

      exit 0
      ;;

    tar2|rpm2)
      echo 'Converting the tar4 installer database format'
      echo '        to the '"$format"' installer database format.'
      echo
      # The next installer uses the same database format. Backup a full
      # database state that it can use as a fresh new database.
      #
      # Everything should go in:
      #  /etc/vmware/
      #              state/
      #
      # But those directories do not have to be referenced,
      # the next installer will do it just after restoring the backup
      # because only it knows if those directories have been created.
      #
      # Also, do not include those directories in the backup, because some
      # versions of tar (1.13.17+ are ok) do not untar directory permissions
      # as described in their documentation.
      make_tmp_dir 'tmpdir' 'vmware-installer'
      mkdir -p "$tmpdir""$gRegistryDir"
      db_add_file "$tmpdir""$gInstallerMainDB" "$gInstallerMainDB" ''
      db_load 'db' "$gInstallerMainDB"
      write() {
        local id="$1"
        local value="$2"
        local dbfile="$3"

        # For the rpm3|tar3 format, a number of keywords were removed.  In their 
        # place a more flexible scheme was implemented for which each has a semantic
        # equivalent:
	#
        #   VNET_HOSTONLY          -> VNET_1_HOSTONLY
        #   VNET_HOSTONLY_HOSTADDR -> VNET_1_HOSTONLY_HOSTADDR
        #   VNET_HOSTONLY_NETMASK  -> VNET_1_HOSTONLY_NETMASK
        #   VNET_INTERFACE         -> VNET_0_INTERFACE
        #
        # Note that we no longer use the samba variables, so these entries are
        # not converted.  These were removed on the upgrade case, so it is not
        # necessary to remove them here.
        #   VNET_SAMBA             -> VNET_1_SAMBA
        #   VNET_SAMBA_MACHINESID  -> VNET_1_SAMBA_MACHINESID
        #   VNET_SAMBA_SMBPASSWD   -> VNET_1_SAMBA_SMBPASSWD
	# 
        # Also note that we perform the conversions needed above (rpm3|tar3
        # case) since we are downgrading two versions.
	# 
	# We undo the changes from rpm2|tar2 to rpm3|tar3 and rpm4|tar4.
        if [ "$id" = 'VNET_1_HOSTONLY' ]; then
          id='VNET_HOSTONLY'
        elif [ "$id" = 'VNET_1_HOSTONLY_HOSTADDR' ]; then
          id='VNET_HOSTONLY_HOSTADDR'
        elif [ "$id" = 'VNET_1_HOSTONLY_NETMASK' ]; then
          id='VNET_HOSTONLY_NETMASK'
        elif [ "$id" = 'VNET_0_INTERFACE' ]; then
          id='VNET_INTERFACE'
        elif echo $id | grep 'VNET_[[:digit:]]\+_DHCP' &>/dev/null; then
           return;
        elif echo $id | grep 'VNET_[[:digit:]]\+_HOSTONLY_SUBNET' &>/dev/null; then
           return;
        fi

        echo 'answer '"$id"' '"$value" >> "$dbfile"
      }
      db_iterate 'db' 'write' "$tmpdir""$gInstallerMainDB"
      files='.'"$gInstallerMainDB"
      if [ -e "$gRegistryDir"/config ]; then
        mkdir -p "$tmpdir""$gRegistryDir"'/state'
        cp "$gRegistryDir"/config "$tmpdir""$gRegistryDir"'/state/config'
        db_add_file "$tmpdir""$gInstallerMainDB" "$gRegistryDir"'/state/config' "$tmpdir""$gRegistryDir"'/state/config'
        files="$files"' .'"$gRegistryDir"'/state/config'
      fi
      # There is no double quote around $files on purpose
      tar -C "$tmpdir" -czopf "$output" $files 2> /dev/null
      rm -rf "$tmpdir"

      exit 0
      ;;

    tar|rpm)
      echo 'Converting the tar4 installer database format'
      echo '        to the '"$format"'  installer database format.'
      echo
      # Backup only the main database file. The next installer ignores
      # new keywords as well as file and directory statements, and deals
      # properly with remove_ statements
      tar -C '/' -czopf "$output" '.'"$gInstallerMainDB" 2> /dev/null

      exit 0
      ;;

    *)
      echo 'Unknown '"$format"' installer database format.'
      echo

      exit 1
      ;;
  esac
}

# Uninstall what has been installed by the installer.
# This should never prompt the user, because it can be annoying if invoked
# from the rpm installer for example.
installer_uninstall() {

  db_load 'db' "$gRegistryDir"'/locations'

  if [ "$db_answer_BINDIR" = '' ]; then
    echo 'Error: Unable to find the binary installation directory (answer BINDIR)'
    echo '       in the installer database file "'"$gRegistryDir"'/locations".'
    echo

    exit 1
  fi

  # Remove the package
  if [ ! -x "$db_answer_BINDIR"'/'"$gUninstaller" ]; then
    echo 'Error: Unable to execute "'"$db_answer_BINDIR"'/'"$gUninstaller"'.'
    echo

    exit 1
  fi
  "$db_answer_BINDIR"/"$gUninstaller" "$@" || exit 1

  exit 0
}

#
# Interface of the methods
#

initialize_globals

case "$1" in
  kind)
    installer_kind
    ;;

  version)
    installer_version
    ;;

  convertdb)
    installer_convertdb "$2" "$3"
    ;;

  uninstall)
    installer_uninstall "$@"
    ;;

  *)
    echo 'Usage: '"`basename "$0"`"' {kind|version|convertdb|uninstall}'
    echo

    exit 1
    ;;
esac

