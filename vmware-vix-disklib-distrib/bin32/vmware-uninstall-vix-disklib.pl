#!/usr/bin/perl -w
# If your copy of perl is not in /usr/bin, please adjust the line above.
#
# Copyright 1998-2010 VMware, Inc.  All rights reserved.
#
# Tar package manager for VMware

use strict;

# Use Config module to update VMware host-wide configuration file
# BEGINNING_OF_CONFIG_DOT_PM
# END_OF_CONFIG_DOT_PM

# BEGINNING_OF_UTIL_DOT_PL
#!/usr/bin/perl

use strict;
no warnings 'once'; # Warns about use of Config::Config in config.pl

# A list of known open-vmware tools packages
#
my @cOpenVMToolsRPMPackages = ("vmware-kmp-debug",
			       "vmware-kmp-default",
			       "vmware-kmp-pae",
			       "vmware-kmp-trace",
			       "vmware-guest-kmp-debug",
			       "vmware-guest-kmp-default",
			       "vmware-guest-kmp-desktop",
			       "vmware-guest-kmp-pae",
			       "open-vm-tools-gui",
			       "open-vm-tools",
			       "libvmtools-devel",
			       "libvmtools0");

my @cOpenVMToolsDEBPackages = (
   "open-vm-dkms",
   "open-vm-source",
   "open-vm-toolbox",
   "open-vm-tools",
   "open-vm-tools-dbg",
    );

# Moved out of config.pl to support $gOption in spacechk_answer
my %gOption;
# Moved from various scripts that include util.pl
my %gHelper;

#
# All the known modules that the config.pl script needs to
# know about.  Modules in this list are searched for when
# we check for non-vmware modules on the system.
#
my @cKernelModules = ('vmblock', 'vmhgfs', 'vmmemctl',
                      'vmxnet', 'vmci', 'vsock',
                      'vmsync', 'pvscsi', 'vmxnet3',
		      'vmwgfx');

#
# This list simply defined what modules need to be included
# in the system ramdisk when we rebuild it.
#
my %cRamdiskKernelModules = (vmxnet3 => 'yes',
			     pvscsi  => 'yes',
			     vmxnet  => 'yes');
#
# This defines module dependencies.  It is a temporary solution
# until we eventually move over to using the modules.xml file
# to get our dependency information.
#
my %cKernelModuleDeps = (vsock => ('vmci'),
			 vmhgfs => ('vmci'));

#
# Module PCI ID and alias definitions.
#
my %cKernelModuleAliases = (
   # PCI IDs first
   'pci:v000015ADd000007C0' => 'pvscsi',
   'pci:v000015ADd00000740' => 'vmci',
   'pci:v000015ADd000007B0' => 'vmxnet3',
   'pci:v000015ADd00000720' => 'vmxnet',
   # Arbitrary aliases next
   'vmware_vsock'    => 'vsock',
   'vmware_vmsync'   => 'vmsync',
   'vmware_vmmemctl' => 'vmmemctl',
   'vmware_vmhgfs'   => 'vmhgfs',
   'vmware_vmblock'  => 'vmblock',
   'vmware_balloon'  => 'vmmemctl',
   'vmw_pvscsi'      => 'pvscsi',
    );

#
# Upstream module names and their corresponding internal module names.
#
my %cUpstrKernelModNames = (
   'vmw_balloon'    => 'vmmemctl',
   'vmw_pvscsi'     => 'pvscsi',
   'vmw_vmxnet3'    => 'vmxnet3',
   'vmware_balloon' => 'vmmemctl',
   'vmxnet3'        => 'vmxnet3',
    );

#
# Table mapping vmware_product() strings to applicable services script or
# Upstart job name.
#

my %cProductServiceTable = (
   'acevm'              => 'acevm',
   'nvdk'               => 'nvdk',
   'player'             => 'vmware',
   'tools-for-freebsd'  => 'vmware-tools.sh',
   'tools-for-linux'    => 'vmware-tools',
   'tools-for-solaris'  => 'vmware-tools',
   'vix-disklib'        => 'vmware-vix-disklib',
   'wgs'                => 'vmware',
   'ws'                 => 'vmware',
   '@@VCLI_PRODUCT@@'   => '@@VCLI_PRODUCT_PATH_NAME@@',
);

#
# Hashes to track vmware modules.
#
my %gNonVmwareModules = ();
my %gVmwareInstalledModules = ();
my %gVmwareRunningModules = ();

my $cTerminalLineSize = 79;

# Flags
my $cFlagTimestamp     =   0x1;
my $cFlagConfig        =   0x2;
my $cFlagDirectoryMark =   0x4;
my $cFlagUserModified  =   0x8;
my $cFlagFailureOK     =  0x10;

# See vmware_service_issue_command
my $cServiceCommandDirect = 0;
my $cServiceCommandSystem = 1;

# Strings for Block Appends.
my $cMarkerBegin = "# Beginning of the block added by the VMware software - DO NOT EDIT\n";
my $cMarkerEnd = "# End of the block added by the VMware software\n";
my $cDBAppendString = 'APPENDED_FILES';

# Constants
my $gWebAccessWorkDir = '/var/log/vmware/webAccess/work';

# util.pl Globals
my %gSystem;

# Needed to access $Config{...}, the Perl system configuration information.
require Config;

# Use the Perl system configuration information to make a good guess about
# the bit-itude of our platform.  If we're running on Solaris we don't have
# to guess and can just ask isainfo(1) how many bits userland is directly.
sub is64BitUserLand {
  if (vmware_product() eq 'tools-for-solaris') {
    if (direct_command(shell_string($gHelper{'isainfo'}) . ' -b') =~ /64/) {
      return 1;
    } else {
      return 0;
    }
  }
  if ($Config::Config{archname} =~ /^(x86_64|amd64)-/) {
    return 1;
  } else {
    return 0;
  }
}

# Return whether or not this is a hosted desktop product.
sub isDesktopProduct {
   return vmware_product() eq "ws" || vmware_product() eq "player";
}

# Return whether or not this is a hosted server product.
sub isServerProduct {
   return vmware_product() eq "wgs";
}

sub isToolsProduct {
   return vmware_product() =~ /tools-for-/;
}

#  Call to specify lib suffix, mainly for FreeBSD tools where multiple versions
#  of the tools are packaged up in 32bit and 64bit instances.  So rather than
#  simply lib or bin, there is lib32-6 or bin64-53, where -6 refers to FreeBSD
#  version 6.0 and 53 to FreeBSD 5.3.
sub getFreeBSDLibSuffix {
   return getFreeBSDSuffix();
}

#  Call to specify lib suffix, mainly for FreeBSD tools where multiple versions
#  of the tools are packaged up in 32bit and 64bit instances.  So rather than
#  simply lib or bin, there is lib32-6 or bin64-53, where -6 refers to FreeBSD
#  version 6.0 and 53 to FreeBSD 5.3.
sub getFreeBSDBinSuffix {
   return getFreeBSDSuffix();
}

#  Call to specify lib suffix, mainly for FreeBSD tools where multiple versions
#  of the tools are packaged up in 32bit and 64bit instances.  In the case of
#  sbin, a lib compatiblity between 5.0 and older systems appeared.  Rather
#  than sbin32, which exists normally for 5.0 and older systems, there needs
#  to be a specific sbin:  sbin32-5.  There is no 64bit set.
sub getFreeBSDSbinSuffix {
   my $suffix = '';
   my $release = `uname -r | cut -f1 -d-`;
   chomp($release);
   if (vmware_product() eq 'tools-for-freebsd' && $release == 5.0) {
      $suffix = '-5';
   } else {
      $suffix = getFreeBSDSuffix();
   }
   return $suffix;
}

sub getFreeBSDSuffix {
  my $suffix = '';

  # On FreeBSD, we ship different builds of binaries for different releases.
  #
  # For FreeBSD 6.0 and higher (which shipped new versions of libc) we use the
  # binaries located in the -6 directories.
  #
  # For releases between 5.3 and 6.0 (which were the first to ship with 64-bit
  # userland support) we use binaries from the -53 directories.
  #
  # For FreeBSD 5.0, we use binaries from the sbin32-5 directory.
  #
  # Otherwise, we just use the normal bin and sbin directories, which will
  # contain binaries predominantly built against 3.2.
  if (vmware_product() eq 'tools-for-freebsd') {
    my $release = `uname -r | cut -f1 -d-`;
    # Tools lowest supported FreeBSD version is now 6.1.  Since the lowest
    # modules we ship are for 6.3, we will just use these instead.  They are
    # suppoed to be binary compatible (hopefully).
    if ($release >= 6.0) {
      $suffix = '-63';
    } elsif ($release >= 5.3) {
      $suffix = '-53';
    } elsif ($release >= 5.0) {
      # sbin dir is a special case here and is handled within getFreeBSDSbinSuffix().
      $suffix = '';
    }
  }

  return $suffix;
}

# Determine what version of FreeBSD we're on and convert that to
# install package values.
sub getFreeBSDVersion {
  my $system_version = direct_command("sysctl kern.osrelease");
  if ($system_version =~ /: *([0-9]+\.[0-9]+)-/) {
    return "$1";
  }

  # If we get here, we were unable to parse kern.osrelease
  return '';
}

# Determine whether SELinux is enabled.
sub is_selinux_enabled {
   if (-x "/usr/sbin/selinuxenabled") {
      my $rv = system("/usr/sbin/selinuxenabled");
      return ($rv eq 0);
   } else {
      return 0;
   }
}

# Wordwrap system: append some content to the output
sub append_output {
  my $output = shift;
  my $pos = shift;
  my $append = shift;

  $output .= $append;
  $pos += length($append);
  if ($pos >= $cTerminalLineSize) {
    $output .= "\n";
    $pos = 0;
  }

  return ($output, $pos);
}

# Wordwrap system: deal with the next character
sub wrap_one_char {
  my $output = shift;
  my $pos = shift;
  my $word = shift;
  my $char = shift;
  my $reserved = shift;
  my $length;

  if (not (($char eq "\n") || ($char eq ' ') || ($char eq ''))) {
    $word .= $char;

    return ($output, $pos, $word);
  }

  # We found a separator.  Process the last word

  $length = length($word) + $reserved;
  if (($pos + $length) > $cTerminalLineSize) {
    # The last word doesn't fit in the end of the line. Break the line before
    # it
    $output .= "\n";
    $pos = 0;
  }
  ($output, $pos) = append_output($output, $pos, $word);
  $word = '';

  if ($char eq "\n") {
    $output .= "\n";
    $pos = 0;
  } elsif ($char eq ' ') {
    if ($pos) {
      ($output, $pos) = append_output($output, $pos, ' ');
    }
  }

  return ($output, $pos, $word);
}

# Wordwrap system: word-wrap a string plus some reserved trailing space
sub wrap {
  my $input = shift;
  my $reserved = shift;
  my $output;
  my $pos;
  my $word;
  my $i;

  if (!defined($reserved)) {
      $reserved = 0;
  }

  $output = '';
  $pos = 0;
  $word = '';
  for ($i = 0; $i < length($input); $i++) {
    ($output, $pos, $word) = wrap_one_char($output, $pos, $word,
                                           substr($input, $i, 1), 0);
  }
  # Use an artifical last '' separator to process the last word
  ($output, $pos, $word) = wrap_one_char($output, $pos, $word, '', $reserved);

  return $output;
}


#
# send_rpc_failed_msgs
#
# A place that gets called when the configurator/installer bails out.
# this ensures that the all necessary RPC end messages are sent.
#
sub send_rpc_failed_msgs {
  send_rpc("toolinstall.installerActive 0");
  send_rpc('toolinstall.end 0');
}


# Print an error message and exit
sub error {
  my $msg = shift;

  # Ensure you send the terminating RPC message before you
  # unmount the CD.
  my $rpcresult = send_rpc('toolinstall.is_image_inserted');
  chomp($rpcresult);

  # Send terminating RPC messages
  send_rpc_failed_msgs();

  print STDERR wrap($msg . 'Execution aborted.' . "\n\n", 0);

  # Now unmount the CD.
  if ("$rpcresult" =~ /1/) {
    eject_tools_install_cd_if_mounted();
  }

  exit 1;
}

# Convert a string to its equivalent shell representation
sub shell_string {
  my $single_quoted = shift;

  $single_quoted =~ s/'/'"'"'/g;
  # This comment is a fix for emacs's broken syntax-highlighting code
  return '\'' . $single_quoted . '\'';
}

# Send an arbitrary RPC command to the VMX
sub send_rpc {
  my $command = shift;
  my $rpctoolSuffix;
  my $rpctoolBinary = '';
  my $libDir;
  my @rpcResultLines;


  if (vmware_product() eq 'tools-for-solaris') {
     $rpctoolSuffix = is64BitUserLand() ? '/sbin/amd64' : '/sbin/i86';
  } else {
     $rpctoolSuffix = is64BitUserLand() ? '/sbin64' : '/sbin32';
  }

  $rpctoolSuffix .= getFreeBSDSbinSuffix() . '/vmware-rpctool';

  # We don't yet know if vmware-rpctool was copied into place.
  # Let's first try getting the location from the DB.
  $libDir = db_get_answer_if_exists('LIBDIR');
  if (defined($libDir)) {
    $rpctoolBinary = $libDir . $rpctoolSuffix;
  }
  if (not (-x "$rpctoolBinary")) {
    # The DB didn't help.  But no matter, we can
    # extract a path to the untarred tarball installer from our
    # current location.  With that info, we can invoke the
    # rpc tool directly out of the staging area.  Woot!
    $rpctoolBinary = "./lib" .  $rpctoolSuffix;
  }

  # If we found the binary, send the RPC.
  if (-x "$rpctoolBinary") {
    open (RPCRESULT, shell_string($rpctoolBinary) . " " .
          shell_string($command) . ' 2> /dev/null |');

    @rpcResultLines = <RPCRESULT>;
    close RPCRESULT;
    return (join("\n", @rpcResultLines));
  } else {
    # Return something so we don't get any undef errors.
    return '';
  }
}

# chmod() that reports errors
sub safe_chmod {
  my $mode = shift;
  my $file = shift;

  if (chmod($mode, $file) != 1) {
    error('Unable to change the access rights of the file ' . $file . '.'
          . "\n\n");
  }
}

# Create a temporary directory
#
# They are a lot of small utility programs to create temporary files in a
# secure way, but none of them is standard. So I wrote this
sub make_tmp_dir {
  my $prefix = shift;
  my $tmp;
  my $serial;
  my $loop;

  $tmp = defined($ENV{'TMPDIR'}) ? $ENV{'TMPDIR'} : '/tmp';

  # Don't overwrite existing user data
  # -> Create a directory with a name that didn't exist before
  #
  # This may never succeed (if we are racing with a malicious process), but at
  # least it is secure
  $serial = 0;
  for (;;) {
    # Check the validity of the temporary directory. We do this in the loop
    # because it can change over time
    if (not (-d $tmp)) {
      error('"' . $tmp . '" is not a directory.' . "\n\n");
    }
    if (not ((-w $tmp) && (-x $tmp))) {
      error('"' . $tmp . '" should be writable and executable.' . "\n\n");
    }

    # Be secure
    # -> Don't give write access to other users (so that they can not use this
    # directory to launch a symlink attack)
    if (mkdir($tmp . '/' . $prefix . $serial, 0755)) {
      last;
    }

    $serial++;
    if ($serial % 200 == 0) {
      print STDERR 'Warning: The "' . $tmp . '" directory may be under attack.' . "\n\n";
    }
  }

  return $tmp . '/' . $prefix . $serial;
}

# Check available space when asking the user for destination directory.
sub spacechk_answer {
  my $msg = shift;
  my $type = shift;
  my $default = shift;
  my $srcDir = shift;
  my $id = shift;
  my $ifdefault = shift;
  my $answer;
  my $space = -1;

  while ($space < 0) {

    if (!defined($id)) {
      $answer = get_answer($msg, $type, $default);
    } else {
      if (!defined($ifdefault)) {
         $answer = get_persistent_answer($msg, $id, $type, $default);
      } else {
         $answer = get_persistent_answer($msg, $id, $type, $default, $ifdefault);
      }
    }

    # XXX check $answer for a null value which can happen with the get_answer
    # in config.pl but not with the get_answer in pkg_mgr.pl.  Moving these
    # (get_answer, get_persistent_answer) routines into util.pl eventually.
    if ($answer && ($space = check_disk_space($srcDir, $answer)) < 0) {
      my $lmsg;
      $lmsg = 'There is insufficient disk space available in ' . $answer
              . '.  Please make at least an additional ' . -$space
              . 'KB available';
      if ($gOption{'default'} == 1) {
        error($lmsg . ".\n");
      }
      print wrap($lmsg . " or choose another directory.\n", 0);
    }
  }
  return $answer;
}


#
# Checks to see if the given module shares a name or PCI id with ours.
# If there's a PCI or name match, send it to check_if_vmw_installed_module
# to see if it's actually ours.
#
# This does the checks in the following order
# 1.  Check for PCI IDs
# 2.  Check for VMware module Aliases
# 3.  Check for module file names (legacy).
#
sub check_if_vmware_module {
  my $modPath = shift;
  my $modInfoCmd = shell_string($gHelper{'modinfo'})
                   . " -F alias $modPath 2>/dev/null";
  my @modInfoOutput = map { chomp; $_ } (`$modInfoCmd`);
  my $line;
  my $modName;
  undef $modName;

  # First check for PCI IDs/Aliases
  foreach $line (@modInfoOutput) {
    $line = reduce_pciid($line);
    $modName = $cKernelModuleAliases{"$line"};
    if (defined $modName) {
      check_if_vmw_installed_module($modName, $modPath);
      return;
    }
  }

  # Finally check the module name.
  if ($modPath =~ m,^.*/(\w+)\.k?o,) {
    foreach my $mod (@cKernelModules) {
      if ("$1" eq $mod) {
        check_if_vmw_installed_module($mod, $modPath);
        return;
      }
    }
    # If the module has been clobbered, the name is in the alias list.
    if (defined $cKernelModuleAliases{$1}) {
        return $cKernelModuleAliases{$1};
    }
  }
}

# This function checks to see if the given module (modName)
# is not in the db file; it adds the result
# to gVmwareInstalledModules if it is in the db file
#
sub check_if_vmw_installed_module {
  my $modName = shift;
  my $modPath = shift;

  if (not -e $modPath) {
    return;
  }

  if (not db_file_in($modPath)) {
    # Add $modName module with path $modPath to bad list

    # Check to see if we have already found a module for this.  If
    # so, there is not much we can do.  Instead just warn the user.
    if (defined $gNonVmwareModules{$modName}) {
      print wrap("WARNING: A module identified as $modName has been found " .
        "at $gNonVmwareModules{$modName} and at $modPath.  " .
        "Leaving both modules in there could potentially " .
        "cause a race condition when a device is added.  " .
        "We recommend you remove one of them, run " .
        "'depmod -a', and then re-run this configurator.\n\n", 0);
    }

    $gNonVmwareModules{$modName} = "$modPath";
  } else {
    # Its one of our modules.  Lets keep track of where they are as
    # they might not be in the standard locations
    $gVmwareInstalledModules{$modName} = "$modPath";
  }
}

# Returns the full path to the first argument. Returns first argument
# if it is already a full path, returns the join() of the second and
# first arguments otherwise.
#
sub get_full_module_path {
  my $module = shift;
  my $path = shift;
  chomp($module);

  # get rid of colon and anything following (if it exists)
  if($module =~ m/(.*):/) {
    $module = "$1";
  }

  my $fullPath;
  # if it starts with a slash, then it's already the full path
  if ($module =~ m/^\//) {
    $fullPath = $module;
  } else {
    # otherwise, get the path from the parameters and append
    $fullPath = join('/', $path, $module);
  }

  if(not -e $fullPath) {
    print wrap("WARNING: A module identified in modules.dep " .
      "could not be found. modules.dep may be out of date. " .
      "We recommend you run 'depmod -a' and then re-run this " .
      "configurator.\n\n", 0);
  }
  return $fullPath;
}

# Extracts the alias and module name from a line, if it starts with "alias";
# Returns empty strings otherwise. Designed for use only when parsing
# modules.alias.
#
sub extract_alias_and_modname {
  my $line = shift;
  my $alias = "";
  my $modname = "";

  if($line =~ m/alias (.*)\s(.*)\s/) {
    $alias = "$1";
    $modname = "$2";
  }
  return ($alias, $modname);
}

# Reduce PCI id by removing trailing data (subvendor, etc) from PCI IDs.
# Returns the reduced PCI id if "pci" start's the string, otherwise returns
# the original string.
#
sub reduce_pciid {
  my $string = shift;
  if ($string=~ m/^(pci:v[0-9A-F]{8}d[0-9A-F]{8})/) {
    $string= "$1";
  }
  return $string;
}

# Looks for a module (*.ko) in modules.dep and returns
# the full path to it if it exists; returns an empty string otherwise
#
sub search_for_module_in_moddep {
  my $modName = shift;
  my $libModPath = shift;

  if(open(MODDEP, "$libModPath/modules.dep")) {
    my $modPath='';
    while(<MODDEP>) {
      my $line = "$_";
      if($line =~ m/(.*$modName):.*/) {
        $modPath = get_full_module_path("$1", "$libModPath");
        last;
      }
    }
    close(MODDEP);
    return $modPath;
  } else {
    error("Unable to open kernel module dependency file\n.");
  }
}

# Returns a list of VMware kernel modules that were
# found on the system that were not placed there by the installer
# by parsing modules.alias.
#
sub populate_vmw_modules_via_aliases_file {
  my $libModPath = shift;

  if(open(MODALIAS, "$libModPath/modules.alias")) {
    my @kernelModulesCopy = @cKernelModules;
    my ($alias, $actualMod, $modName, $modPath);
    while(<MODALIAS>) {
      ($alias, $actualMod) = extract_alias_and_modname("$_");
      $alias = reduce_pciid($alias);

      $modName = $cKernelModuleAliases{"$alias"};
      if (defined $modName) {
        # then a module alias matched one of our modules

        $modPath = search_for_module_in_moddep("$actualMod.ko", $libModPath);
        # remove $modName from @kernelModulesCopy
        @kernelModulesCopy = grep { $_ ne $modName } @kernelModulesCopy;

        check_if_vmw_installed_module($modName, $modPath);
      }
    }

    # search for any of the remaining modules for which
    # we did not find a module alias. Have to do this
    # second because it uses kernelModulesCopy, which is changed above
    foreach my $mod (@kernelModulesCopy) {
      $modPath = search_for_module_in_moddep("$mod.ko", $libModPath);
      if (not $modPath eq '') {
        check_if_vmw_installed_module($mod, $modPath);
      }
    }
    close(MODALIAS);
  } else {
    error("Unable to open modules.alias file\n.");
  }
}

# Returns a list of VMWare kernel modules that were
# found on the system that were not placed there by the installer
# by parsing modules.dep, modinfo-ing the module, and parsing
# the output of modinfo.
#
sub populate_vmw_modules_via_modinfo {
  my $libModPath = shift;

  if (open(MODULESDEP, "$libModPath/modules.dep")) {
    my $modPath = '';
    while (<MODULESDEP>) {
      if (/^(.*\.k?o):.*$/) {
        #
        # Then the module may not be there.  In Ubuntu 9.04, modules.dep
        # no longer has a full path for the modules.  Therefore we must
        # try out both a full path and one relative to the modules
        # directory of the currently running kernel.
        #

        $modPath = get_full_module_path("$1","$libModPath");

        if (defined $modPath) {
          check_if_vmware_module($modPath);
        }
      }
    }
    close(MODULESDEP);
  } else {
    error("Unable to open kernel module dependency file\n.");
  }
}

# check_for_vmw_mods_in_kernel
#
# Checks /sys/module for our kernel modules.  This only works on the
# running kernel.
#
sub check_for_vmw_mods_in_kernel {
   my $k;
   my $v;

   return unless (getKernRel() eq $gSystem{'uts_release'});

   while (($k, $v) = each %cUpstrKernelModNames) {
      my $path = join('/', '/sys/module', $k);
      if (-e $path) {
         $gVmwareRunningModules{$v} = $k;
      }
   }
}


# Returns a list of VMware kernel modules that were
# found on the system that were not placed there by the installer.
# Also checks the running kernel for modules that were built in when
# the kernel was compiled.
sub populate_vmware_modules {
  my $libModPath = join('/','/lib/modules', getKernRel());

  # can't continue without the modules.dep file
  system(shell_string($gHelper{'depmod'}) . ' -a');
  if (not -e "$libModPath/modules.dep") {
    error("Unable to find kernel module dependency file\n.");
  }

  if (-e "$libModPath/modules.alias") {
    populate_vmw_modules_via_aliases_file($libModPath);
  } else {
    populate_vmw_modules_via_modinfo($libModPath);
  }

  check_for_vmw_mods_in_kernel();
}


# Call restorecon on the supplied file if selinux is enabled
sub restorecon {
  my $file = shift;

   if (is_selinux_enabled()) {
     # we suppress warnings from restorecon. bug #1008386:
     system("/sbin/restorecon 2>/dev/null " . $file);
     # Return a 1, restorecon was called.
     return 1;
   }

  # If it is not enabled, return a -1, restorecon was NOT called.
  return -1;
}

# Append a clearly delimited block to an unstructured text file
# Result:
#  1 on success
#  -1 on failure
sub block_append {
   my $file = shift;
   my $begin = shift;
   my $block = shift;
   my $end = shift;

   if (not open(BLOCK, '>>' . $file)) {
      return -1;
   }

   print BLOCK $begin . $block . $end;

   if (not close(BLOCK)) {
     # Even if close fails, make sure to call restorecon.
     restorecon($file);
     return -1;
   }

   # Call restorecon to set SELinux policy for this file.
   restorecon($file);
   return 1;
}

# Append a clearly delimited block to an unstructured text file
# and add this file to an "answer" entry in the locations db
#
# Result:
#  1 on success
#  -1 on failure
sub block_append_with_db_answer_entry {
   my $file = shift;
   my $block = shift;

   return -1 if (block_append($file, $cMarkerBegin, $block, $cMarkerEnd) < 0);

   # get the list of already-appended files
   my $list = db_get_answer_if_exists($cDBAppendString);

   # No need to check if there's anything in the list because
   # db_add_answer removes the existing answer with the same name
   if ($list) {
      $list = join(':', $list, $file);
   } else {
      $list = $file;
   }
   db_add_answer($cDBAppendString, $list);

   return 1;
}


# Insert a clearly delimited block to an unstructured text file
#
# Uses a regexp to find a particular spot in the file and adds
# the block at the first regexp match.
#
# Result:
#  1 on success
#  0 on no regexp match (nothing added)
#  -1 on failure
sub block_insert {
   my $file = shift;
   my $regexp = shift;
   my $begin = shift;
   my $block = shift;
   my $end = shift;
   my $line_added = 0;
   my $tmp_dir = make_tmp_dir('vmware-block-insert');
   my $tmp_file = $tmp_dir . '/tmp_file';

   if (not open(BLOCK_IN, '<' . $file) or
       not open(BLOCK_OUT, '>' . $tmp_file)) {
      return -1;
   }

   foreach my $line (<BLOCK_IN>) {
     if ($line =~ /($regexp)/ and not $line_added) {
       print BLOCK_OUT $begin . $block . $end;
       $line_added = 1;
     }
     print BLOCK_OUT $line;
   }

   if (not close(BLOCK_IN) or not close(BLOCK_OUT)) {
     return -1;
   }

   if (not system(shell_string($gHelper{'mv'}) . " $tmp_file $file")) {
     return -1;
   }

   remove_tmp_dir($tmp_dir);

   # Call restorecon to set SELinux policy for this file.
   restorecon($file);

   # Our return status is 1 if successful, 0 if nothing was added.
   return $line_added
}


# Test if specified file contains line matching regular expression
# Result:
#  undef on failure
#  first matching line on success
sub block_match {
   my $file = shift;
   my $block = shift;
   my $line = undef;

   if (open(BLOCK, '<' . $file)) {
      while (defined($line = <BLOCK>)) {
         chomp $line;
         last if ($line =~ /$block/);
      }
      close(BLOCK);
   }
   return defined($line);
}


# Remove all clearly delimited blocks from an unstructured text file
# Result:
#  >= 0 number of blocks removed on success
#  -1 on failure
sub block_remove {
   my $src = shift;
   my $dst = shift;
   my $begin = shift;
   my $end = shift;
   my $count;
   my $state;

   if (not open(SRC, '<' . $src)) {
      return -1;
   }

   if (not open(DST, '>' . $dst)) {
      close(SRC);
      return -1;
   }

   $count = 0;
   $state = 'outside';
   while (<SRC>) {
      if      ($state eq 'outside') {
         if ($_ eq $begin) {
            $state = 'inside';
            $count++;
         } else {
            print DST $_;
         }
      } elsif ($state eq 'inside') {
         if ($_ eq $end) {
            $state = 'outside';
         }
      }
   }

   if (not close(DST)) {
      close(SRC);
      # Even if close fails, make sure to call restorecon on $dst.
      restorecon($dst);
      return -1;
   }

   # $dst file has been modified, call restorecon to set the
   #  SELinux policy for it.
   restorecon($dst);

   if (not close(SRC)) {
      return -1;
   }

   return $count;
}

# Similar to block_remove().  Find the delimited text, bracketed by $begin and $end,
# and filter it out as the file is written out to a tmp file. Typicaly, block_remove()
# is used in the pattern:  create tmp dir, create tmp file, block_remove(), mv file,
# remove tmp dir. This encapsulates the pattern.
sub block_restore {
  my $src_file = shift;
  my $begin_marker = shift;
  my $end_marker = shift;
  my $tmp_dir = make_tmp_dir('vmware-block-restore');
  my $tmp_file = $tmp_dir . '/tmp_file';
  my $rv;
  my @sb;

  @sb = stat($src_file);

  $rv = block_remove($src_file, $tmp_file, $begin_marker, $end_marker);
  if ($rv >= 0) {
    system(shell_string($gHelper{'mv'}) . ' ' . $tmp_file . ' ' . $src_file);
    safe_chmod($sb[2], $src_file);
  }
  remove_tmp_dir($tmp_dir);

  # Call restorecon on the source file.
  restorecon($src_file);

  return $rv;
}

# match the output of 'uname -s' to the product. These are compared without
# case sensitivity.
sub DoesOSMatchProduct {

 my %osProductHash = (
    'tools-for-linux'   => 'linux',
    'tools-for-solaris' => 'sunos',
    'tools-for-freebsd' => 'freebsd'
 );

 my $OS = `uname -s`;
 chomp($OS);

 return ($osProductHash{vmware_product()} =~ m/$OS/i) ? 1 : 0;

}

# Remove leading and trailing whitespaces
sub remove_whitespaces {
  my $string = shift;

  $string =~ s/^\s*//;
  $string =~ s/\s*$//;
  return $string;
}

# Ask a question to the user and propose an optional default value
# Use this when you don't care about the validity of the answer
sub query {
    my $message = shift;
    my $defaultreply = shift;
    my $reserved = shift;
    my $reply;
    my $default_value = $defaultreply eq '' ? '' : ' [' . $defaultreply . ']';
    my $terse = 'no';

    # Allow the script to limit output in terse mode.  Usually dictated by
    # vix in a nested install and the '--default' option.
    if (db_get_answer_if_exists('TERSE')) {
      $terse = db_get_answer('TERSE');
      if ($terse eq 'yes') {
        $reply = remove_whitespaces($defaultreply);
        return $reply;
      }
    }

    # Reserve some room for the reply
    print wrap($message . $default_value, 1 + $reserved);

    # This is what the 1 is for
    print ' ';

    if ($gOption{'default'} == 1) {
      # Simulate the enter key
      print "\n";
      $reply = '';
    } else {
      $reply = <STDIN>;
      $reply = '' unless defined($reply);
      chomp($reply);
    }

    print "\n";
    $reply = remove_whitespaces($reply);
    if ($reply eq '') {
      $reply = $defaultreply;
    }
    return $reply;
}

# Execute the command passed as an argument
# _without_ interpolating variables (Perl does it by default)
sub direct_command {
  return `$_[0]`;
}

# If there is a pid for this process, consider it running.
sub check_is_running {
  my $proc_name = shift;
  my $rv = system(shell_string($gHelper{'pidof'}) . " " . $proc_name . " > /dev/null");
  return $rv eq 0;
}

# OS-independent method of loading a kernel module by module name
# Returns true (non-zero) if the operation succeeded, false otherwise.
sub kmod_load_by_name {
    my $modname = shift; # IN: Module name
    my $doSilent = shift; # IN: Flag to indicate whether loading should be done silently

    my $silencer = '';
    if (defined($doSilent) && $doSilent) {
	$silencer = ' >/dev/null 2>&1';
    }

    if (defined($gHelper{'modprobe'})) { # Linux
	return !system(shell_string($gHelper{'modprobe'}) . ' ' . shell_string($modname)
		       . $silencer);
    } elsif (defined($gHelper{'kldload'})) { # FreeBSD
	return !system(shell_string($gHelper{'kldload'}) . ' ' . shell_string($modname)
		       . $silencer);
    } elsif (defined($gHelper{'modload'})) { # Solaris
	return !system(shell_string($gHelper{'modload'}) . ' ' . shell_string($modname)
		       . $silencer);
    }

    return 0; # Failure
}

# OS-independent method of loading a kernel module by object path
# Returns true (non-zero) if the operation succeeded, false otherwise.
sub kmod_load_by_path {
    my $modpath = shift; # IN: Path to module object file
    my $doSilent = shift; # IN: Flag to indicate whether loading should be done silently
    my $doForce = shift; # IN: Flag to indicate whether loading should be forced
    my $probe = shift; # IN: 1 if to probe only, 0 if to actually load

    my $silencer = '';
    if (defined($doSilent) && $doSilent) {
	$silencer = ' >/dev/null 2>&1';
    }

    if (defined($gHelper{'insmod'})) { # Linux
	return !system(shell_string($gHelper{'insmod'}) . ($probe ? ' -p ' : ' ')
		       . ((defined($doForce) && $doForce) ? ' -f ' : ' ')
		       . shell_string($modpath)
		       . $silencer);
    } elsif (defined($gHelper{'kldload'})) { # FreeBSD
	return !system(shell_string($gHelper{'kldload'}) . ' ' . shell_string($modpath)
		       . $silencer);
    } elsif (defined($gHelper{'modload'})) { # Solaris
	return !system(shell_string($gHelper{'modload'}) . ' ' . shell_string($modpath)
		       . $silencer);
    }

    return 0; # Failure
}

# OS-independent method of unloading a kernel module by name
# Returns true (non-zero) if the operation succeeded, false otherwise.
sub kmod_unload {
    my $modname = shift;     # IN: Module name
    my $doRecursive = shift; # IN: Whether to also try loading modules that
                             # become unused as a result of unloading $modname

    if (defined($gHelper{'modprobe'})
	&& defined($doRecursive) && $doRecursive) { # Linux (with $doRecursive)
	return !system(shell_string($gHelper{'modprobe'}) . ' -r ' . shell_string($modname)
		       . ' >/dev/null 2>&1');
    } elsif (defined($gHelper{'rmmod'})) { # Linux (otherwise)
	return !system(shell_string($gHelper{'rmmod'}) . ' ' . shell_string($modname)
		       . ' >/dev/null 2>&1');
    } elsif (defined($gHelper{'kldunload'})) { # FreeBSD
	return !system(shell_string($gHelper{'kldunload'}) . ' ' . shell_string($modname)
		       . ' >/dev/null 2>&1');
    } elsif (defined($gHelper{'modunload'})) { # Solaris
	# Solaris won't let us unload by module name, so we have to find the ID from modinfo
	my $aline;
	my @lines = split('\n', direct_command(shell_string($gHelper{'modinfo'})));

	foreach $aline (@lines) {
	    chomp($aline);
	    my($amodid, $dummy2, $dummy3, $dummy4, $dummy5, $amodname) = split(/\s+/, $aline);

	    if ($modname eq $amodname) {
		return !system(shell_string($gHelper{'modunload'}) . ' -i ' . $amodid
			       . ' >/dev/null 2>&1');
	    }
	}

	return 0; # Failure - module not found
    }

    return 0; # Failure
}

#
# check to see if the certificate files exist (and
# that they appear to be a valid certificate).
#
sub certificateExists {
  my $certLoc = shift;
  my $openssl_exe = shift;
  my $certPrefix = shift;
  my $ld_lib_path = $ENV{'LD_LIBRARY_PATH'};
  my $libdir = db_get_answer('LIBDIR') . '/lib';
  $ld_lib_path .= ';' . $libdir . '/libssl.so.0.9.8;' . $libdir . '/libcrypto.so.0.9.8';

  my $ld_lib_string = "LD_LIBRARY_PATH='" . $ld_lib_path . "'";
  return ((-e "$certLoc/$certPrefix.crt") &&
          (-e "$certLoc/$certPrefix.key") &&
          !(system($ld_lib_string . " " . shell_string("$openssl_exe") . ' x509 -in '
                   . shell_string("$certLoc") . "/$certPrefix.crt " .
                   ' -noout -subject > /dev/null 2>&1')));
}

# Helper function to create SSL certificates
sub createSSLCertificates {
  my ($openssl_exe, $vmware_version, $certLoc, $certPrefix, $unitName) = @_;
  my $certUniqIdent = "(564d7761726520496e632e)";
  my $certCnf;
  my $curTime = time();
  my $hostname = direct_command(shell_string($gHelper{"hostname"}));

  my $cTmpDirPrefix = "vmware-ssl-config";
  my $tmpdir;

  if (certificateExists($certLoc, $openssl_exe, $certPrefix)) {
    print wrap("Using Existing SSL Certificate.\n", 0);
    return;
  }

  # Create the directory
  if (! -e $certLoc) {
    create_dir($certLoc, $cFlagDirectoryMark);
  }

  $tmpdir = make_tmp_dir($cTmpDirPrefix);
  $certCnf = "$tmpdir/certificate.cnf";
  if (not open(CONF, '>' . $certCnf)) {
    error("Unable to open $certCnf to create SSL certificate.\n")
  }
  print CONF <<EOF;
  # Conf file that we will use to generate SSL certificates.
RANDFILE                = $tmpdir/seed.rnd
[ req ]
default_bits		= 1024
default_keyfile 	= $certPrefix.key
distinguished_name	= req_distinguished_name

#Don't encrypt the key
encrypt_key             = no
prompt                  = no

string_mask = nombstr

[ req_distinguished_name ]
countryName= US
stateOrProvinceName     = California
localityName            = Palo Alto
0.organizationName      = VMware, Inc.
organizationalUnitName  = $unitName
commonName              = $hostname
unstructuredName        = ($curTime),$certUniqIdent
emailAddress            = ssl-certificates\@vmware.com
EOF
  close(CONF);

  my $ld_lib_path = $ENV{'LD_LIBRARY_PATH'};
  my $libdir = db_get_answer('LIBDIR') . '/lib';
  $ld_lib_path .= ';' . $libdir . '/libssl.so.0.9.8;' . $libdir . '/libcrypto.so.0.9.8';
  my $ld_lib_string = "LD_LIBRARY_PATH='" . $ld_lib_path . "'";

  system($ld_lib_string . " " . shell_string("$openssl_exe") . ' req -new -x509 -keyout '
         . shell_string("$certLoc") . '/' . shell_string("$certPrefix")
         . '.key -out ' . shell_string("$certLoc") . '/'
         . shell_string("$certPrefix") . '.crt -config '
         . shell_string("$certCnf") . ' -days 5000 > /dev/null 2>&1');
  db_add_file("$certLoc/$certPrefix.key", $cFlagTimestamp);
  db_add_file("$certLoc/$certPrefix.crt", $cFlagTimestamp);

  remove_tmp_dir($tmpdir);
  # Make key readable only by root (important)
  safe_chmod(0400, "$certLoc" . '/' . "$certPrefix" . '.key');

  # Let anyone read the certificate
  safe_chmod(0444, "$certLoc" . '/' . "$certPrefix" . '.crt');
}

# Install a pair of S/K startup scripts for a given runlevel
sub link_runlevel {
   my $level = shift;
   my $service = shift;
   my $S_level = shift;
   my $K_level = shift;

   #
   # Create the S symlink
   #
   install_symlink(db_get_answer('INITSCRIPTSDIR') . '/' . $service,
                   db_get_answer('INITDIR') . '/rc' . $level . '.d/S'
                   . $S_level . $service);

   #
   # Create the K symlink
   #
   install_symlink(db_get_answer('INITSCRIPTSDIR') . '/' . $service,
                   db_get_answer('INITDIR') . '/rc' . $level . '.d/K'
                   . $K_level . $service);
}

# Create the links for VMware's services taking the service name and the
# requested levels
sub link_services {
   my @fields;
   my $service = shift;
   my $S_level = shift;
   my $K_level = shift;

   # Try using insserv if it is available.
   my $init_style = db_get_answer_if_exists('INIT_STYLE');

   if ($gHelper{'insserv'} ne '') {
     if (0 == system(shell_string($gHelper{'insserv'}) . ' '
                     . shell_string(db_get_answer('INITSCRIPTSDIR')
                                    . '/' . $service) . ' >/dev/null 2>&1')) {
       return;
     }
   }
   if ("$init_style" eq 'lsb') {
     # Then we have gotten here, but gone past the insserv section, indicating
     # that insserv cannot be found.  Warn the user...
     print wrap("WARNING: The installer initially used the " .
                "insserv application to setup the vmware-tools service.  " .
                "That application did not run successfully.  " .
                "Please re-install the insserv application or check your settings.  " .
                "This script will now attempt to manually setup the " .
                "vmware-tools service.\n\n", 0);
   }

   # Now try using chkconfig if available.
   # Note: RedHat's chkconfig reads LSB INIT INFO if present.
   if ($gHelper{'chkconfig'} ne '') {
     if (0 == system(shell_string($gHelper{'chkconfig'}) . ' '
                     . $service . ' reset')) {
       return;
     }
   }
   if ("$init_style" eq 'chkconfig') {
     # Then we have gotten here, but gone past the chkconfig section, indicating
     # that chkconfig cannot be found.  Warn the user..
     print wrap("WARNING: The installer initially used the " .
                "chkconfig application to setup the vmware-tools service.  " .
                "That application did not run successfully.  " .
                "Please re-install the chkconfig application or check your settings.  " .
                "This script will now attempt to manually setup the " .
                "vmware-tools service.\n\n", 0);
   }

   # Now try using update-rc.d if available.
   if ($gHelper{'update-rc.d'} ne '') {
     if (0 == system(shell_string($gHelper{'update-rc.d'}) . " " . $service
	             . " start " . $S_level . " S ."
                     . " start " . $K_level . " 0 6 .")) {
       return;
     }
   }
   if ("$init_style" eq 'update-rc.d') {
     # Then we have gotten here, but gone past the update-rc.d section, indicating
     # that update-rc.d cannot be found.  Warn the user..
     print wrap("WARNING: The installer initially used the " .
                "'udpate-rc.d' to setup the vmware-tools service.  " .
                "That command cannot be found.  " .
                "Please re-install the 'sysv-rc' package.  " .
                "This script will now attempt to manually setup the " .
                "vmware-tools service.", 0);
   }

   if (distribution_info() eq "debian") {
     # Set up vmware to start at run level S
     install_symlink(db_get_answer('INITSCRIPTSDIR') . '/' . $service,
                     db_get_answer('INITDIR') . '/rcS.d/S' . $S_level . $service);
   }
   else {
     # Set up vmware to start/stop at run levels 2, 3 and 5
     link_runlevel(2, $service, $S_level, $K_level);
     link_runlevel(3, $service, $S_level, $K_level);
     link_runlevel(5, $service, $S_level, $K_level);
   }

   # Set up vmware to stop at run levels 0 and 6
   my $K_prefix = "K";
   if (distribution_info() eq "debian") {
     $K_prefix = "S";
   }
   install_symlink(db_get_answer('INITSCRIPTSDIR') . '/' . $service,
                   db_get_answer('INITDIR') . '/rc0' . '.d/' . $K_prefix
                   . $K_level . $service);
   install_symlink(db_get_answer('INITSCRIPTSDIR') . '/' . $service,
                   db_get_answer('INITDIR') . '/rc6' . '.d/' . $K_prefix
                   . $K_level . $service);
}


# Emulate a simplified ls program for directories
sub internal_ls {
  my $dir = shift;
  my @fn;

  opendir(LS, $dir) or return ();
  @fn = grep(!/^\.\.?$/, readdir(LS));
  closedir(LS);

  return @fn;
}


# Emulate a simplified dirname program
sub internal_dirname {
  my $path = shift;
  my $pos;

  $path = dir_remove_trailing_slashes($path);

  $pos = rindex($path, '/');
  if ($pos == -1) {
    # No slash
    return '.';
  }

  if ($pos == 0) {
    # The only slash is at the beginning
    return '/';
  }

  return substr($path, 0, $pos);
}

sub internal_dirname_vcli {
  my $path = shift;
  my $pos;

  $path = dir_remove_trailing_slashes($path);

  $pos = rindex($path, '/');
  if ($pos == -1) {
    # No slash
    return '.';
  }

  my @arr1 = split(/\//, $path);

  # if "/bin" is top directory return parent directory as base directory
  if ( $arr1[scalar(@arr1) -1] eq "bin" ) {
    return substr($path, 0, $pos);
  }

  return $path;
}

#
# unconfigure_autostart_legacy --
#
#      Remove VMware-added blocks relating to vmware-user autostart from
#      pre-XDG resource files, scripts, etc.
#
# Results:
#      OpenSuSE:        Revert xinitrc.common.
#      Debian/Ubuntu:   Remove script from Xsession.d.
#      xdm:             Revert xdm-config(s).
#      gdm:             None.  (gdm mechanism used install_symlink, so that will be
#                       cleaned up separately.)
#
# Side effects:
#      None.
#

sub unconfigure_autostart_legacy {
   my $markerBegin = shift;     # IN: block begin marker
   my $markerEnd = shift;       # IN: block end marker

   if (!defined($markerBegin) || !defined($markerEnd)) {
      return;
   }

   my $chompedMarkerBegin = $markerBegin; # block_match requires chomped markers
   chomp($chompedMarkerBegin);

   #
   # OpenSuSE (xinitrc.common)
   #
   my $xinitrcCommon = '/etc/X11/xinit/xinitrc.common';
   if (-f $xinitrcCommon && block_match($xinitrcCommon, $chompedMarkerBegin)) {
      block_restore($xinitrcCommon, $markerBegin, $markerEnd);
   }

   #
   # Debian (Xsession.d) - We forgot to simply call db_add_file() after
   # creating this one.
   #
   my $dotdScript = '/etc/X11/Xsession.d/99-vmware_vmware-user';
   if (-f $dotdScript && !db_file_in($dotdScript)) {
      unlink($dotdScript);
   }

   #
   # xdm
   #
   my @xdmcfgs = ("/etc/X11/xdm/xdm-config");
   my $x11Base = db_get_answer_if_exists('X11DIR');
   if (defined($x11Base)) {
      push(@xdmcfgs, "$x11Base/lib/X11/xdm/xdm-config");
   }
   foreach (@xdmcfgs) {
      if (-f $_ && block_match($_, "!$chompedMarkerBegin")) {
         block_restore($_, "!$markerBegin", "!$markerEnd");
      }
   }
}

# Check a mountpoint to see if it hosts the guest tools install iso.
sub check_mountpoint_for_tools {
   my $mountpoint = shift;
   my $foundit = 0;

   if (vmware_product() eq 'tools-for-solaris') {
      if ($mountpoint =~ /vmwaretools$/ ||
          $mountpoint =~ /\/media\/VMware Tools$/) {
         $foundit = 1;
      }
   } elsif (opendir CDROMDIR, $mountpoint) {
      my @dircontents = readdir CDROMDIR;
      foreach my $entry ( @dircontents ) {
         if (vmware_product() eq 'tools-for-linux') {
            if ($entry =~ /VMwareTools-.*\.tar\.gz$/) {
               $foundit = 1;
            }
         } elsif (vmware_product() eq 'tools-for-freebsd') {
            if ($entry =~ /vmware-freebsd-tools\.tar\.gz$/) {
               $foundit = 1;
            }
         }
      }
      closedir(CDROMDIR);
   }
   return $foundit;
}

# Try to eject the guest tools install cd so the user doesn't have to manually.
sub eject_tools_install_cd_if_mounted {
   # TODO: Add comments to the other code which generates the filenames
   #       and volumeids which this code is now dependent upon.
   my @candidate_mounts;
   my $device;
   my $mountpoint;
   my $fstype;
   my $rest;
   my $eject_cmd = '';
   my $eject_failed = 0;
   my $eject_really_failed = 0;

   # For each architecture, first collect a list of mounted cdroms.
   if (vmware_product() eq 'tools-for-linux') {
      $eject_cmd = internal_which('eject');
      if (open(MOUNTS, '</proc/mounts')) {
         while (<MOUNTS>) {
            ($device, $mountpoint, $fstype, $rest) = split;
            # note: /proc/mounts replaces spaces with \040
            $device =~ s/\\040/\ /g;
            $mountpoint =~ s/\\040/\ /g;
            if ($fstype eq "iso9660" && $device !~ /loop/ ) {
               push(@candidate_mounts, "${device}::::${mountpoint}");
            }
         }
         close(MOUNTS);
      }
   } elsif (vmware_product() eq 'tools-for-freebsd' and
	    -x internal_which('mount')) {
      $eject_cmd = internal_which('cdcontrol') . " eject";
      my @mountlines = split('\n', direct_command(internal_which('mount')));
      foreach my $mountline (@mountlines) {
         chomp($mountline);
         if ($mountline =~ /^(.+)\ on\ (.+)\ \(([0-9a-zA-Z]+),/) {
	   $device = $1;
	   $mountpoint = $2;
	   $fstype = $3;

	   # If the device begins with /dev/md it will most likely
	   # be the equivalent of a loopback mount in linux.
	   if ($fstype eq "cd9660" && $device !~ /^\/dev\/md/) {
	     push(@candidate_mounts, "${device}::::${mountpoint}");
	   }
	 }
       }
   } elsif (vmware_product() eq 'tools-for-solaris') {
      $eject_cmd = internal_which('eject');
      # If this fails, don't bother trying to unmount, or error.
      if (open(MNTTAB, '</etc/mnttab')) {
         while (<MNTTAB>) {
            ($device, $rest) = split("\t", $_);
            # I don't think there are actually ever comments in /etc/mnttab.
            next if $device =~ /^#/;
            if ($device =~ /vmwaretools$/ ||
                $rest =~ /\/media\/VMware Tools$/) {
               $mountpoint = $rest;
               $mountpoint =~ s/(.*)\s+hsfs.*/$1/;
               push(@candidate_mounts, "${device}::::${mountpoint}");
            }
         }
         close(MNTTAB);
      }
   }

   # For each mounted cdrom, check if it's vmware guest tools installer,
   # and if so, try to eject it, then verify.
   foreach my $candidate_mount (@candidate_mounts) {
      ($device, $mountpoint) = split('::::',$candidate_mount);
      if (check_mountpoint_for_tools($mountpoint)) {
         print wrap("Found VMware Tools CDROM mounted at " .
                    "${mountpoint}. Ejecting device $device ...\n");

         # Freebsd doesn't auto unmount along with eject.
         if (vmware_product() eq 'tools-for-freebsd' and
	     -x internal_which('umount')) {
            # If this fails, the eject will fail, and the user will see
            # the appropriate output.
            direct_command(internal_which('umount') .
                           ' "' . $device . '"');
         }
	 my @output = ();
	 if ($eject_cmd ne '') {
	   open(CMDOUTPUT, "$eject_cmd $device 2>&1 |");
	   @output = <CMDOUTPUT>;
	   close(CMDOUTPUT);
	   $eject_failed = $?;
	 } else {
	   $eject_failed = 1;
	 }

         # For unknown reasons, eject can succeed, but return error, so
         # double check that it really failed before showing the output to
         # the user.  For more details see bug170327.
         if ($eject_failed && check_mountpoint_for_tools($mountpoint)) {
            foreach my $outputline (@output) {
               print wrap ($outputline, 0);
            }

            # $eject_really_failed ensures this message is not printed
            # multiple times.
            if (not $eject_really_failed) {
	      if ($eject_cmd eq '') {
		 print wrap ("No eject (or equivilant) command could be " .
			     "located.\n");
	       }
	      print wrap ("Eject Failed:  If possible manually eject the " .
			  "Tools installer from the guest cdrom mounted " .
			  "at $mountpoint before canceling tools install " .
			  "on the host.\n", 0);

	      $eject_really_failed = 1;
            }
         }
      }
   }
}


# Compares variable length version strings against one another.
# Returns 1 if the first version is greater, -1 if the second
# version is greater, or 0 if they are equal.
sub dot_version_compare {
  my $str1 = shift;
  my $str2 = shift;

  if ("$str1" eq '' or "$str2" eq '') {
    if ("$str1" eq '' and "$str2" eq '') {
      return 0;
    } else {
      return (("$str1" eq '') ? -1 : 1);
    }
  }

  if ("$str1" =~ /[^0-9\.]+/ or "$str2" =~ /[^0-9\.]+/) {
    error("Bad character detected in dot_version_compare.\n");
  }

  my @arr1 = split(/\./, "$str1");
  my @arr2 = split(/\./, "$str2");
  my $indx = 0;
  while(1) {
     if (!defined $arr1[$indx] and !defined $arr2[$indx]) {
        return 0;
     }

     $arr1[$indx] = 0 if not defined $arr1[$indx];
     $arr2[$indx] = 0 if not defined $arr2[$indx];

     if ($arr1[$indx] != $arr2[$indx]) {
        return (($arr1[$indx] > $arr2[$indx]) ? 1 : -1);
     }
     $indx++;
  }
  error("NOT REACHED IN DOT_VERSION_COMPARE\n");
}


# Checks for versioning information in both the system module
# and the shipped module.  If it finds information in the sytem
# module, it compares it against the version information of the
# shipped module and will use whatever module is newer.
# Returns 1 if it uses the shipped module (and 0 otherwise).
sub install_x_module {
  my $shippedMod = shift;
  my $systemMod = shift;
  my $modinfo = internal_which('modinfo');
  my $shippedModVer = '';
  my $systemModVer = '';
  my $installShippedModule = 0;
  my $line;

  if (not -r $shippedMod) {
    error("Could not read $shippedMod\n");
  }

  if ("$modinfo" ne '' and -r "$systemMod") {
    open (SHIPPED_MOD_VER, "$modinfo $shippedMod |");
    open (SYSTEM_MOD_VER, "$modinfo $systemMod |");

    foreach $line (<SHIPPED_MOD_VER>) {
      if ($line =~ /version: +([0-9\.]+)/) {
        $shippedModVer = "$1";
        last;
      }
    }
    foreach $line (<SYSTEM_MOD_VER>) {
      if ($line =~ /version: +([0-9\.]+)/) {
        $systemModVer = "$1";
        last;
      }
    }

    close (SHIPPED_MOD_VER);
    close (SYSTEM_MOD_VER);

    chomp ($shippedModVer);
    chomp ($systemModVer);

    if ("$systemModVer" eq '' or
	dot_version_compare ("$shippedModVer", "$systemModVer") > 0) {
      # Then the shipped module is newer than sytem module.
      $installShippedModule = 1;
    }
  } else {
    # If it has no version, assume the one we ship is newer.
    $installShippedModule = 1;
  }

  if ($gOption{'clobber-xorg-modules'} or $installShippedModule) {
    install_x_module_no_checks($shippedMod, $systemMod);
    return 1;
  }
  return 0;
}

sub install_x_module_no_checks {
   my $shippedMod = shift;
   my $systemMod = shift;
   my %patch;
   undef %patch;

   # Ensure we have a unique backup suffix for this file.
   # Also strip off anything sh wouldn't like.  Bug 502544
   my $bkupExt = internal_basename($systemMod);
   $bkupExt =~ s/^(\w+).*$/$1/;
   backup_file_to_restore($systemMod, $bkupExt);
   install_file ("$shippedMod", "$systemMod", \%patch, 1);
}

# Returns the tuple ($halScript, $halName) if the system
# has scripts to control HAL.
#
sub get_hal_script_name {
   my $initDir = shell_string(db_get_answer('INITSCRIPTSDIR'));
   $initDir =~ s/\'//g; # Remove quotes

   my @halguesses = ("haldaemon", "hal");
   my $halScript = undef;
   my $halName = undef;

   # Attempt to find the init script for the HAL service.
   # It should be one of the names in our list of guesses.
   foreach my $hname (@halguesses) {
      if (-f "$initDir/$hname") {
         $halScript = "$initDir/$hname";
         $halName = "$hname";
      }
   }

   if (vmware_product() eq 'tools-for-solaris') {
      # In Solaris 11, use svcadm to handle HAL.
      # XXX: clean this up on main.
      my $svcadmBin = internal_which('svcadm');
      if (system("$svcadmBin refresh hal >/dev/null 2>&1") eq 0) {
         $halScript = 'svcadm';
         $halName = 'hal';
      }
   }

   return ($halScript, $halName);
}

sub restart_hal {
   my $servicePath = internal_which("service");
   my $halScript = undef;
   my $halName = undef;

   ($halScript, $halName) = get_hal_script_name();

   # Hald does time stamp based cache obsolescence check, and it won't
   # reload new fdi if it has cache file with future timestamp.
   # Let's cleanup the cache file before restarting hald to get around
   # this problem.
   unlink('/var/cache/hald/fdi-cache');

   if ($halScript eq 'svcadm') {
      # Solaris svcadm.
      my $svcadmBin = internal_which('svcadm');
      system("$svcadmBin restart hal");
   } elsif (-d '/etc/init' and $servicePath ne '' and defined($halName)) {
      # Upstart case.
      system("$servicePath $halName restart");
   } elsif (defined($halScript)) {
      # Traditional init script restart case.
      system($halScript . ' restart');
   } else {
      print "Could not locate hal daemon init script.\n";
   }
}


sub prelink_fix {
  my $source = "/etc/vmware-tools/vmware-tools-prelink.conf";
  my $dest = '/etc/prelink.conf.d/vmware-tools-prelink.conf';
  my $prelink_file = '/etc/prelink.conf';
  my $libdir = db_get_answer_if_exists('LIBDIR');
  my %patch;

  if (defined($libdir)) {
    %patch = ('@@LIBDIR@@' => $libdir);
  } else {
    error ("LIBDIR must be defined before prelink_fix is called.\n");
  }

  if (-d internal_dirname($dest)) {
    install_file($source, $dest, \%patch, 1);
  } elsif (-f $prelink_file) {
    # Readin our prelink file, do the appropreiate substitutions, and
    # block insert it into the prelink.conf file.

    my $key;
    my $value;
    my $line;
    my $to_append = '';

    if (not open(FH, $source)) {
      error("Could not open $source\n");
    }

    foreach $line (<FH>) {
      chomp ($line);
      while (($key, $value) = each %patch) {
	$line =~ s/$key/$value/g;
      }
      $to_append .= $line . "\n";
    }

    close FH;

    if (block_insert($prelink_file, '^ *-b', $cMarkerBegin,
		     $to_append, $cMarkerEnd) == 1) {
      db_add_answer('PRELINK_CONFED', $prelink_file);
    }
  }
}


sub prelink_restore {
  my $prelink_file = db_get_answer_if_exists('PRELINK_CONFED');

  if (defined $prelink_file) {
    block_restore($prelink_file, $cMarkerBegin, $cMarkerEnd);
  }
}

# Determines if the system at hand needs to have timer
# based audio support disabled in pulse.  Make this call
# based on the version of pulseaudio installed on the system.
#
sub pulseNeedsTimerBasedAudioDisabled {
   my $pulseaudioBin = internal_which("pulseaudio");
   my $cmd = "$pulseaudioBin --version";
   my $verStr = '0';

   if (-x $pulseaudioBin) {
      open(OUTPUT, "$cmd |");
      foreach my $line (<OUTPUT>) {
	 chomp $line;
	 if ($line =~ /pulseaudio *([0-9\.]+)/) {
	     $verStr = $1;
	     last
	 }
      }
      if (dot_version_compare($verStr, "0.9.19") ge 0) {
	 # Then pulseaudio's version is >= 0.9.19
	 return 1;
      }
   }

   return 0
}

# Disables timer based audio scheduling in the default config
# file for PulseAudio
#
sub pulseDisableTimerBasedAudio {
   my $cfgFile = '/etc/pulse/default.pa';
   my $regex = qr/^ *load-module +module-(udev|hal)-detect$/;
   my $tmpDir = make_tmp_dir('vmware-pulse');
   my $tmpFile = $tmpDir . '/tmp_file';
   my $fileModified = 0;

   if (not open(ORGPCF, "<$cfgFile") or
       not open(NEWPCF, ">$tmpFile")) {
      return 0;
   }

   foreach my $line (<ORGPCF>) {
      chomp $line;
      if ($line =~ $regex and $line !~ /tsched/) {
	 # add the flag if its not already there.
	 print NEWPCF "$line tsched=0\n";
	 $fileModified = 1;
      } else {
	 # just print the line.
	 print NEWPCF "$line\n";
      }
   }

   close ORGPCF;
   close NEWPCF;

   if ($fileModified) {
      backup_file_to_restore($cfgFile, "orig");
      system(join(' ', $gHelper{'cp'}, $tmpFile, $cfgFile));
      restorecon($cfgFile);
      db_add_answer('PULSE_AUDIO_CONFED', $cfgFile);
   }

  remove_tmp_dir($tmpDir);
}


##
# Checks to see if any of the package names in a given list
# are currently installed by RPM on the system.
# @param - A list of RPM packages to check for.
# @returns - A list of the installed RPM packages that this
#            function checked for and found (if any).
#
sub checkRPMForPackages {
   my @pkgList = @_;
   my @instPkgs;
   my $bin = internal_which('rpm');
   my $cmd = join(' ', $bin, '-qa --queryformat \'%{NAME}\n\'');

   if (-x $bin) {
      open(OUTPUT, "$cmd |");
      foreach my $instPkgName (<OUTPUT>) {
	 chomp $instPkgName;
	 foreach my $pkgName (@pkgList) {
	    if ($pkgName eq $instPkgName) {
	       push @instPkgs, $instPkgName;
	    }
	 }
      }
      close(OUTPUT);
   }
   return @instPkgs
}

##
# Checks to see if any of the package names in a given list
# are currently installed by dpkg on the system.
# @param - A list of deb packages to check for.
# @returns - A list of the installed deb packages that this
#            function checked for and found (if any).
#
sub checkDPKGForPackages {
   my @pkgList = @_;
   my @instPkgs;
   my $bin = internal_which('dpkg-query');
   my $cmd = join(' ', $bin, '--show --showformat=\'${Package}\n\'');

   if (-x $bin) {
      open(OUTPUT, "$cmd |");
      foreach my $instPkgName (<OUTPUT>) {
	 chomp $instPkgName;
	 foreach my $pkgName (@pkgList) {
	    if ($pkgName eq $instPkgName) {
	       push @instPkgs, $instPkgName;
	    }
	 }
      }
      close(OUTPUT);
   }
   return @instPkgs
}


##
# Attempts to remove the given list of RPM packages
# @param - List of rpm packages to remove
# @returns - -1 if there was an internal error, otherwise
#            the return value of RPM
#
sub removeRPMPackages {
   my @pkgList = @_;
   my $bin = internal_which('rpm');
   my @cmd = (("$bin", '-e'), @pkgList);

   if (-x $bin) {
      return system(@cmd);
   } else {
      return -1;
   }
}


##
# Attempts to remove the given list of DEB packages
# @param - List of deb packages to remove
# @returns - -1 if there was an internal error, otherwise
#            the return value of dpkg
#
sub removeDEBPackages {
   my @pkgList = @_;
   my $bin = internal_which('dpkg');
   my @cmd = (("$bin", '-r'), @pkgList);

   if (-x $bin) {
      return system(@cmd);
   } else {
      return -1;
   }
}


##
# locate_upstart_jobinfo
#
# Determine whether Upstart is supported, and if so, return the path in which
# Upstart jobs should be installed and any job file suffix.
#
# @retval ($path, $suffix) Path containing Upstart jobs, job suffix (ex: .conf).
# @retval ()               Upstart unsupported or unable to determine job path.
#

sub locate_upstart_jobinfo() {
   my $initctl = internal_which('initctl');
   my $retval;
   # Don't bother checking directories unless initctl is available and
   # indicates that Upstart is active.
   if ($initctl ne '' and ( -x $initctl )) {
      my $initctl_version_string = direct_command(shell_string($initctl) . " version");
      if (($initctl_version_string =~ /upstart ([\d\.]+)/) and
          # XXX Fix dot_version_compare to support a comparison like 0.6.5 to 0.6.
          (dot_version_compare($1, "0.6.0") >= 0)) {
         my $jobPath = "/etc/init";
         if ( -d $jobPath ) {
            my $suffix = "";

            foreach my $testSuffix (".conf") {
               if (glob ("$jobPath/*$testSuffix")) {
                  $suffix = $testSuffix;
                  last;
               }
            }

            return ($jobPath, $suffix);
         }
      }
   }

   return ();
}


##
# vmware_service_basename
#
# Simple product name -> service script map accessor.  (See
# $cProductServiceTable.)
#
# @return Service script basename on valid product, undef otherwise.
#
sub vmware_service_basename {
   return $cProductServiceTable{vmware_product()};
}


##
# vmware_service_path
#
# @return Valid service script's path relative to INITSCRIPTSDIR unless
# vmware_product() has no such script.
#

sub vmware_service_path {
   my $basename = vmware_service_basename();

   return $basename
      ? join('/', db_get_answer('INITSCRIPTSDIR'), $basename)
      : undef;
}


##
# vmware_service_issue_command
#
# Executes a VMware services script, determined by locations database contents
# and product type, with a single command parameter.
#
# @param[in] $useSystem If true, uses system().  Else uses direct_command().
# @param[in] @commands  List of commands passed to services script or initctl
#                       (ex: start, stop, status vm).
#
# @returns Return value from system() or direct_command().
#

sub vmware_service_issue_command {
   my $useSystem = shift;
   my @argv;
   my @escapedArgv;
   my $cmd;

   # Upstart/initctl case.
   if (db_get_answer_if_exists('UPSTARTJOB')) {
      my $service = vmware_service_basename();
      my $initctl = internal_which('initctl');

      error("ASSERT: Failed to determine my service name.\n") unless defined $service;

      @argv = ($initctl, @_, $service);

   # Legacy SYSV style.
   } else {
      @argv = (vmware_service_path(), @_);
   }

   # Escape parameters, then join by a single space.
   foreach (@argv) {
      push(@escapedArgv, shell_string($_));
   }
   $cmd = join(' ', @escapedArgv);

   return $useSystem ? system($cmd) : direct_command($cmd);
}


##
# does_solaris_package_exist
#
# Executes a system call to check if the given package (passed in as
# a parameter) exists.
#
# @param[in] $packageName
#
# @returns 1 (true) if package exists, 0 (false) otherwise
#

sub does_solaris_package_exist {
   my $packageName = shift;

   system("pkginfo $packageName > /dev/null 2>&1");
   return $? == 0 ? 1 : 0;
}

##
# is_esx_virt_env
#
# Returns true if the VM is runing in an ESX virtual environment,
# false otherwise.
# @returns - 1 (true) if in ESX, 0 (false) otherwise
#
sub is_esx_virt_env {
   my $ans = 0;
   my $sbinDir = db_get_answer('SBINDIR');
   my $checkvm = join('/', $sbinDir, 'vmware-checkvm');

   if (-x $checkvm) {
      my $output = `$checkvm -p 2>&1`;
      $ans = 1 if ($output =~ m/ESX Server/);
   }

   return $ans;
}

##
# disable_module
#
# Sets the appropriate flags to disable the module.
# @returns - Nothing useful.
#
sub disable_module {
   my $mod = shift;

   set_manifest_component("$mod", 'FALSE');
   db_add_answer(uc("$mod") . '_CONFED', 'no');

   return;
}


##
# getKernRel
#
# Returns the release of the kernel in question.  Defaults to the
# running kernel unless the user has set the --kernel-version option.
#
sub getKernRel {
   if ($gOption{'kernel_version'} ne '') {
      return $gOption{'kernel_version'};
   } else {
      return $gSystem{'uts_release'};
   }
}


##
# getModDBKey
#
# Creates and returns the DB key for a module based on a little
# system information
#
sub getModDBKey {
   my $modName = shift;
   my $tag = shift;
   my $kernel = getKernRel();

   # Remove non alpha-numeric characters
   $kernel =~ s/[\.\-\+]//g;
   my $key = join('_', uc($modName), $kernel, $tag);

   return $key;
}


##
# removeDuplicateEntries
#
# Removes duplicate entries from a given string and delimeter
# @param - string to cleanse
# @param - the delimeter
# @returns - String without duplicate entries.
#
sub removeDuplicateEntries {
   my $string = shift;
   my $delim = shift;
   my $newStr = '';

   if (not defined $string or not defined $delim) {
      error("Missing parameters in removeDuplicateEntries\n.");
   }

   foreach my $subStr (split($delim, $string)) {
      if ($newStr !~ /(^|$delim)$subStr($delim|$)/ and $subStr ne '') {
	 if ($newStr ne '') {
	    $newStr = join($delim, $newStr, $subStr);
	 } else {
	    $newStr = $subStr;
	 }
      }
   }

   return $newStr;
}


##
# addEntDBList
#
# Adds an entry to a list within the DB.  This function also removes
# duplicate entries from the list.
#
sub addEntDBList {
   my $dbKey = shift;
   my $ent = shift;

   if (not defined $dbKey or $dbKey eq '') {
      error("Bad dbKey value in addEntDBList.\n");
   }

   if ($ent =~ m/,/) {
      error("New list entry can not contain commas.\n");
   }

   my $list = db_get_answer_if_exists($dbKey);
   my $newList = $list ? join(',', $list, $ent) : $ent;
   $newList = removeDuplicateEntries($newList, ',');
   db_add_answer($dbKey, $newList);
}


##
# internalMv
#
# mv command for Perl that works across file system boundaries.  The rename
# function may not work across FS boundaries and I don't want to introduce
# a dependency on File::Copy (at least not with this installer/configurator).
#
sub internalMv {
   my $src = shift;
   my $dst = shift;
   return system("mv $src $dst");
}


##
# addTextToKVEntryInFile
#
# Despite the long and confusing function name, this function is very
# useful.  If you have a key value entry in a file, this function will
# allow you to add an entry to it based on a special regular expression.
# This regular expression must capture the pre-text, the values, and any
# post text by using regex back references.
# @param - Path to file
# @param - The regular expression.  See example below...
# @param - The delimeter between values
# @param - The new entry
# @returns - 1 if the file was modified, 0 otherwise.
#
# For example, if I have
#   foo = 'bar,baz';
# I can add 'biz' to the values by calling this function with the proper
# regex.  A regex for this would look like '^(foo = ')(\.*)(;)$'.  The
# delimeter is ',' and the entry would be 'biz'.  The result should look
# like
#   foo = 'bar,baz,biz';
#
# NOTE1:  This function will only add to the first KV pair found.
#
sub addTextToKVEntryInFile {
   my $file = shift;
   my $regex = shift;
   my $delim = shift;
   my $entry = shift;
   my $modified = 0;
   my $firstPart;
   my $origValues;
   my $newValues;
   my $lastPart;

   $regex = qr/$regex/;

   if (not open(INFILE, "<$file")) {
      error("addTextToKVEntryInFile: File $file not found\n");
   }

   my $tmpDir = make_tmp_dir('vmware-file-mod');
   my $tmpFile = join('/', $tmpDir, 'new-file');
   if (not open(OUTFILE, ">$tmpFile")) {
      error("addTextToKVEntryInFile: Failed to open output file\n");
   }

   foreach my $line (<INFILE>) {
      if ($line =~ $regex and not $modified) {
         # We have a match.  $1 and $2 have to be deifined; $3 is optional
         if (not defined $1 or not defined $2) {
            error("addTextToKVEntryInFile: Bad regex.\n");
         }
         $firstPart = $1;
         $origValues = $2;
         $lastPart = ((defined $3) ? $3 : '');
         chomp $firstPart;
         chomp $origValues;
         chomp $lastPart;

         # Modify the origValues and remove duplicates
         # Handle white space as well.
         if ($origValues =~ /^\s*$/) {
            $newValues = $entry;
         } else {
            $newValues = join($delim, $origValues, $entry);
            $newValues = removeDuplicateEntries($newValues, $delim);
         }
         print OUTFILE join('', $firstPart, $newValues, $lastPart, "\n");

         $modified = 1;
      } else {
         print OUTFILE $line;
      }
   }

   close(INFILE);
   close(OUTFILE);

   return 0 unless (internalMv($tmpFile, $file) eq 0);
   remove_tmp_dir($tmpDir);

   # Our return status is 1 if successful, 0 if nothing was added.
   return $modified;
}


##
# removeTextInKVEntryInFile
#
# Does exactly the opposite of addTextToKVEntryFile.  It will remove
# all instances of the text entry in the first KV pair that it finds.
# @param - Path to file
# @param - The regular expression.  See example above...
# @param - The delimeter between values
# @param - The entry to remove
# @returns - 1 if the file was modified, 0 otherwise.
#
# NOTE1:  This function will only remove from the first KV pair found.
#
sub removeTextInKVEntryInFile {
   my $file = shift;
   my $regex = shift;
   my $delim = shift;
   my $entry = shift;
   my $modified = 0;
   my $firstPart;
   my $origValues;
   my $newValues = '';
   my $lastPart;

   $regex = qr/$regex/;

   if (not open(INFILE, "<$file")) {
      error("removeTextInKVEntryInFile:  File $file not found\n");
   }

   my $tmpDir = make_tmp_dir('vmware-file-mod');
   my $tmpFile = join('/', $tmpDir, 'new-file');
   if (not open(OUTFILE, ">$tmpFile")) {
      error("removeTextInKVEntryInFile:  Failed to open output file $tmpFile\n");
   }

   foreach my $line (<INFILE>) {
      if ($line =~ $regex and not $modified) {
         # We have a match.  $1 and $2 have to be deifined; $3 is optional
         if (not defined $1 or not defined $2) {
            error("removeTextInKVEntryInFile:  Bad regex.\n");
         }
         $firstPart = $1;
         $origValues = $2;
         $lastPart = ((defined $3) ? $3 : '');
         chomp $firstPart;
         chomp $origValues;
         chomp $lastPart;

         # Modify the origValues and remove duplicates
         # If $origValues is just whitespace, no need to modify $newValues.
         if ($origValues !~ /^\s*$/) {
            foreach my $existingEntry (split($delim, $origValues)) {
               if ($existingEntry ne $entry) {
                  if ($newValues eq '') {
                     $newValues = $existingEntry; # avoid adding unnecessary whitespace
                  } else {
                     $newValues = join($delim, $newValues, $existingEntry);
                  }
               }
            }
         }
         print OUTFILE join('', $firstPart, $newValues, $lastPart, "\n");

         $modified = 1;
      } else {
         print OUTFILE $line;
      }
   }

   close(INFILE);
   close(OUTFILE);

   return 0 unless (internalMv($tmpFile, $file));
   remove_tmp_dir($tmpDir);

   # Our return status is 1 if successful, 0 if nothing was added.
   return $modified;
}
# END_OF_UTIL_DOT_PL

# Needed for WIFSIGNALED and WTERMSIG
use POSIX;
use Config;

# Constants
my $cInstallerFileName = 'vmware-install.pl';
my $cModuleUpdaterFileName = 'install.pl';
my $cInstallerDir = './installer';
my $cStartupFileName = $cInstallerDir . '/services.sh';
my $cRegistryDir = '/etc/vmware';
my $cInstallerMainDB = $cRegistryDir . '/locations';
my $cInstallerObject = $cRegistryDir . '/installer.sh';
my $cConfFlag = $cRegistryDir . '/not_configured';
my $gDefaultAuthdPort = 902;
my $cServices = '/etc/services';
my $dspMarkerFile = '/usr/lib/vmware-tools/dsp';
my $cVixMarkerBegin = "# Beginning of the block added by the VMware VIX software\n";
my $cVixMarkerEnd = "# End of the block added by the VMware VIX software\n";
# Constant defined as the smallest vmnet that is allowed
my $gMinVmnet = '0';
# Linux doesn't allow more than 7 characters in the names of network
# interfaces. We prefix host only interfaces with 'vmnet' leaving us only 2
# characters.
# Constant defined as the largest vmnet that is allowed
my $gMaxVmnet = '99';

my $open_vm_compat = 0;

my $cChkconfigInfo = <<END;
# Basic support for IRIX style chkconfig
# chkconfig: 235 03 99
# description: Manages the services needed to run VMware software
END

my $cLSBInitInfo = <<END;
### BEGIN INIT INFO
# Provides: vmware-tools
# Required-Start: \$local_fs
# Required-Stop: \$local_fs
# X-Start-Before: \$network
# X-Stop-After: \$network
# Default-Start: 2 3 5
# Default-Stop: 0 6
# Short-Description: VMware Tools service
# Description: Manages the services needed to run VMware Tools
### END INIT INFO
END

# MANIFEST file and hash for installing ACE VMs
my $cManifestFilename = 'MANIFEST';
my %gManifest;
my $gACEVMUpdate = 0;
my $gHostVmplDir = "/etc/vmware/vmware-ace";
my $gPlayerBundle = '';

# Has the uninstaller been installed?
my $gIsUninstallerInstalled;

# Hash of multi architecture supporting products
my %multi_arch_products;
# Hash of product conflicts
my %product_conflicts;

# BEGINNING OF THE SECOND LIBRARY FUNCTIONS
# Global variables
my $gRegistryDir;
my $gFirstCreatedDir = undef;
my $gStateDir;
my $gInstallerMainDB;
my $gInstallerObject;
my $gConfFlag;
my $gUninstallerFileName;
my $gConfigurator;
my $gConfig;
my $gConfigFile;
my @gOldUninstallers = '';

my %gDBAnswer;
my %gDBFile;
my %gDBDir;
my %gDBLink;
my %gDBMove;

my @gLower; # list of modules whose versions are less than the shipped
my @gMissing; # list of modules not installed

# list of files that are config failes users may modify
my %gDBUserModified;
my %gDBConfig;

#
# db_clear
#
# Unsets all variables modified in the db_load process
#
sub db_clear {
  undef %gDBAnswer;
  undef %gDBFile;
  undef %gDBDir;
  undef %gDBLink;
  undef %gDBMove;
  undef %gDBConfig;
  undef %gDBUserModified;
}

#
# db_load
#
# Reads in the database file specified in $gInstallerMainDB and loads the values
# into the 7 variables mentioned below.
#
sub db_load {
  db_clear();
  open(INSTALLDB, '<' . $gInstallerMainDB)
    or error('Unable to open the installer database '
             . $gInstallerMainDB . ' in read-mode.' . "\n\n");
  while (<INSTALLDB>) {
    chomp;
    if (/^answer (\S+) (.+)$/) {
      $gDBAnswer{$1} = $2;
    } elsif (/^answer (\S+)/) {
      $gDBAnswer{$1} = '';
    } elsif (/^remove_answer (\S+)/) {
      delete $gDBAnswer{$1};
    } elsif (/^file (.+) (\d+)$/) {
      $gDBFile{$1} = $2;
    } elsif (/^file (.+)$/) {
      $gDBFile{$1} = 0;
    } elsif (/^remove_file (.+)$/) {
      delete $gDBFile{$1};
    } elsif (/^directory (.+)$/) {
      $gDBDir{$1} = '';
    } elsif (/^remove_directory (.+)$/) {
      delete $gDBDir{$1};
    } elsif (/^link (\S+) (\S+)/) {
      $gDBLink{$2} = $1;
    } elsif (/^move (\S+) (\S+)/) {
      $gDBMove{$2} = $1;
    } elsif (/^config (\S+)/) {
      $gDBConfig{$1} = 'config';
    } elsif (/^modified (\S+)/) {
      $gDBUserModified{$1} = 'modified';
    }
  }
  close(INSTALLDB);
}

# Open the database on disk in append mode
sub db_append {
  if (not open(INSTALLDB, '>>' . $gInstallerMainDB)) {
    error('Unable to open the installer database ' . $gInstallerMainDB . ' in append-mode.' . "\n\n");
  }
  # Force a flush after every write operation.
  # See 'Programming Perl', p. 110
  select((select(INSTALLDB), $| = 1)[0]);
}

# Add a file to the tar installer database
# flags:
#  0x1 write time stamp
sub db_add_file {
  my $file = shift;
  my $flags = shift;

  if ($flags & 0x1) {
    my @statbuf;

    @statbuf = stat($file);
    if (not (defined($statbuf[9]))) {
      error('Unable to get the last modification timestamp of the destination file ' . $file . '.' . "\n\n");
    }

    $gDBFile{$file} = $statbuf[9];
    print INSTALLDB 'file ' . $file . ' ' . $statbuf[9] . "\n";
  } else {
    $gDBFile{$file} = 0;
    print INSTALLDB 'file ' . $file . "\n";
  }
}

# Remove a file from the tar installer database
sub db_remove_file {
  my $file = shift;

  print INSTALLDB 'remove_file ' . $file . "\n";
  delete $gDBFile{$file};
}

# Remove a directory from the tar installer database
sub db_remove_dir {
  my $dir = shift;

  print INSTALLDB 'remove_directory ' . $dir . "\n";
  delete $gDBDir{$dir};
}

# Determine if a file belongs to the tar installer database
sub db_file_in {
  my $file = shift;

  return defined($gDBFile{$file});
}

# Determine if a directory belongs to the tar installer database
sub db_dir_in {
  my $dir = shift;

  return defined($gDBDir{$dir});
}

# Return the timestamp of an installed file
sub db_file_ts {
  my $file = shift;

  return $gDBFile{$file};
}

# Add a directory to the tar installer database
sub db_add_dir {
  my $dir = shift;

  $gDBDir{$dir} = '';
  print INSTALLDB 'directory ' . $dir . "\n";
}

# Remove an answer from the tar installer database
sub db_remove_answer {
  my $id = shift;

  if (defined($gDBAnswer{$id})) {
    print INSTALLDB 'remove_answer ' . $id . "\n";
    delete $gDBAnswer{$id};
  }
}

# Add an answer to the tar installer database
sub db_add_answer {
  my $id = shift;
  my $value = shift;

  db_remove_answer($id);
  $gDBAnswer{$id} = $value;
  print INSTALLDB 'answer ' . $id . ' ' . $value . "\n";
}

# Retrieve an answer that must be present in the database
sub db_get_answer {
  my $id = shift;

  if (not defined($gDBAnswer{$id})) {
    error('Unable to find the answer ' . $id . ' in the installer database ('
          . $gInstallerMainDB . '). You may want to re-install '
          . vmware_product_name() . "." .  "\n\n");
  }

  return $gDBAnswer{$id};
}

# Retrieves an answer if it exists in the database, else returns undef;
sub db_get_answer_if_exists {
  my $id = shift;
  if (not defined($gDBAnswer{$id})) {
    return undef;
  }
  if ($gDBAnswer{$id} eq '') {
    return undef;
  }
  return $gDBAnswer{$id};
}

# Save the tar installer database
sub db_save {
  close(INSTALLDB);
}

# Parse an installer database and return a specified answer if it exists
sub ext_db_get_answer_if_exists {
   # parse arguments
   my $InstallDB = shift;
   my $id = shift;

   # temporary database
   my %DBAnswer;
   my %DBFile;
   my %DBDir;
   my %DBLink;
   my %DBMove;

   # Open the installdb, or error.
   open(INSTDB, '<' . $InstallDB)
      or error('Unable to open the installer database '
               . $InstallDB . ' in read-mode.' . "\n\n");

   # parse the installdb
   while (<INSTDB>) {
      chomp;
      if (/^answer (\S+) (.+)$/) {
         $DBAnswer{$1} = $2;
      } elsif (/^answer (\S+)/) {
         $DBAnswer{$1} = '';
      } elsif (/^remove_answer (\S+)/) {
         delete $DBAnswer{$1};
      } elsif (/^file (.+) (\d+)$/) {
         $DBFile{$1} = $2;
      } elsif (/^file (.+)$/) {
         $DBFile{$1} = 0;
      } elsif (/^remove_file (.+)$/) {
         delete $DBFile{$1};
      } elsif (/^directory (.+)$/) {
         $DBDir{$1} = '';
      } elsif (/^remove_directory (.+)$/) {
         delete $DBDir{$1};
      } elsif (/^link (\S+) (\S+)/) {
         $DBLink{$2} = $1;
      } elsif (/^move (\S+) (\S+)/) {
         $DBMove{$2} = $1;
      }
   }
   close(INSTDB);

   # return the requested answer key value
   if (not defined($DBAnswer{$id})) {
      return undef;
   } elsif($DBAnswer{$id} eq '') {
      return undef;
   } else {
      return $DBAnswer{$id};
   }
}

# uninstall a product
#
# returns true if product was successfully uninstalled, false otherwise
sub uninstall_product {
   my $product = shift;

   # try to use an installer object if it exists
   my $InstallerObject = $cRegistryDir . '-' . $product . '/installer.sh';
   if ( -x $InstallerObject ) {
      system(shell_string($InstallerObject) . ' uninstall');
      if (!($? >> 8 eq 0)) {
         print wrap("warning: could not uninstall $product with its installer object\n\n", 0);
      } else {
         return 1;
      }
   }

   # check for an uninstaller in BINDIR
   my $InstallDB = $cRegistryDir . '-' . $product . '/locations';
   if ( -e $InstallDB ) {
      my $bindir = ext_db_get_answer_if_exists($InstallDB, 'BINDIR');
      if (not(defined($bindir))) {
         print wrap("warning: could not find uninstaller for $product", 0);
         return 0;
      }
      my $uninstaller = $bindir . '/vmware-uninstall-' . $product . '.pl';
      if (! -x $uninstaller) {
         print wrap("warning: could not find uninstaller for $product", 0);
         return 0;
      }
      system(shell_string($uninstaller));
      if (!($? >> 8 eq 0)) {
         print wrap("warning: could not uninstall $product with its uninstaller", 0);
      } else {
         return 1;
      }
   }

   # nothing worked
   return 0;
}

# END OF THE SECOND LIBRARY FUNCTIONS

# BEGINNING OF THE LIBRARY FUNCTIONS
# Global variables
my %gAnswerSize;
my %gCheckAnswerFct;

# Tell if the user is the super user
sub is_root {
  return $> == 0;
}

# Contrary to a popular belief, 'which' is not always a shell builtin command.
# So we can not trust it to determine the location of other binaries.
# Moreover, SuSE 6.1's 'which' is unable to handle program names beginning with
# a '/'...
#
# Return value is the complete path if found, or '' if not found
sub internal_which {
  my $bin = shift;

  if (substr($bin, 0, 1) eq '/') {
    # Absolute name
    if ((-f $bin) && (-x $bin)) {
      return $bin;
    }
  } else {
    # Relative name
    my @paths;
    my $path;

    if (index($bin, '/') == -1) {
      # There is no other '/' in the name
      @paths = split(':', $ENV{'PATH'});
      foreach $path (@paths) {
   my $fullbin;

   $fullbin = $path . '/' . $bin;
   if ((-f $fullbin) && (-x $fullbin)) {
     return $fullbin;
   }
      }
    }
  }

  return '';
}

# Check the validity of an answer whose type is yesno
# Return a clean answer if valid, or ''
sub check_answer_binpath {
  my $answer = shift;
  my $source = shift;

  my $fullpath = internal_which($answer);
  if (not ("$fullpath" eq '')) {
    return $fullpath;
  }

  if ($source eq 'user') {
    print wrap('The answer "' . $answer . '" is invalid. It must be the complete name of a binary file.' . "\n\n", 0);
  }
  return '';
}
$gAnswerSize{'binpath'} = 20;
$gCheckAnswerFct{'binpath'} = \&check_answer_binpath;

# Prompts the user if a binary is not found
# Return value is:
#  '': the binary has not been found
#  the binary name if it has been found
sub DoesBinaryExist_Prompt {
  my $bin = shift;
  my $answer;

  $answer = check_answer_binpath($bin, 'default');
  if (not ($answer eq '')) {
    return $answer;
  }

  if (get_answer('Setup is unable to find the "' . $bin . '" program on your machine. Please make sure it is installed. Do you want to specify the location of this program by hand?', 'yesno', 'yes') eq 'no') {
    return '';
  }

  return get_answer('What is the location of the "' . $bin . '" program on your machine?', 'binpath', '');
}

# Install a file permission
sub install_permission {
  my $src = shift;
  my $dst = shift;
  my @statbuf;
  my $mode;
  @statbuf = stat($src);
  if (not (defined($statbuf[2]))) {
    error('Unable to get the access rights of source file "' . $src . '".' . "\n\n");
  }

  # ACE packages may be installed from CD/DVDs, which don't have the same file
  # permissions of the original package (no write permission). Since these
  # packages are installed by a user under a single directory, it's safe to do
  # 'u+w' on everything.
  $mode = $statbuf[2] & 07777;
  if (vmware_product() eq 'acevm') {
    $mode |= 0200;
  }
  safe_chmod($mode, $dst);
}

# Emulate a simplified sed program
# Return 1 if success, 0 if failure
# XXX as a side effect, if the string being replaced is '', remove
# the entire line.  Remove this, once we have better "block handling" of
# our config data in config files.
sub internal_sed {
  my $src = shift;
  my $dst = shift;
  my $append = shift;
  my $patchRef = shift;
  my @patchKeys;

  if (not open(SRC, '<' . $src)) {
    return 0;
  }
  if (not open(DST, (($append == 1) ? '>>' : '>') . $dst)) {
    return 0;
  }

  @patchKeys = keys(%$patchRef);
  if ($#patchKeys == -1) {
    while(defined($_ = <SRC>)) {
      print DST $_;
    }
  } else {
    while(defined($_ = <SRC>)) {
      my $patchKey;
      my $del = 0;

      foreach $patchKey (@patchKeys) {
        if (s/$patchKey/$$patchRef{$patchKey}/g) {
          if ($_ eq "\n") {
            $del = 1;
          }
        }
      }
      next if ($del);
      print DST $_;
    }
  }

  close(SRC);
  close(DST);
  return 1;
}

# Check if a file name exists
sub file_name_exist {
  my $file = shift;

  # Note: We must test for -l before, because if an existing symlink points to
  #       a non-existing file, -e will be false
  return ((-l $file) || (-e $file))
}

# Check if a file name already exists and prompt the user
# Return 0 if the file can be written safely, 1 otherwise
sub file_check_exist {
  my $file = shift;

  if (not file_name_exist($file)) {
    return 0;
  }

  my $lib_dir = $Config{'archlib'} || $ENV{'PERL5LIB'} || $ENV{'PERLLIB'} ;
  my $share_dir = $Config{'installprivlib'} || $ENV{'PERLSHARE'} ;

  # do not overwrite perl module files
  if($file =~ m/$lib_dir|$share_dir/) {
    return 1;
  }


  # The default must make sure that the product will be correctly installed
  # We give the user the choice so that a sysadmin can perform a normal
  # install on a NFS server and then answer 'no' NFS clients
  return (get_answer('The file ' . $file . ' that this program was about to '
                     . 'install already exists. Overwrite?',
                     'yesno', 'yes') eq 'yes') ? 0 : 1;
}

# Install one file
# flags are forwarded to db_add_file()
sub install_file {
  my $src = shift;
  my $dst = shift;
  my $patchRef = shift;
  my $flags = shift;

  uninstall_file($dst);
  # because any modified config file is not removed but left in place,
  # it will already exist and coveniently avoid processing here.  It's
  # not added to the db so it will not be uninstalled next time.
  if (file_check_exist($dst)) {
    return;
  }
  # The file could be a symlink to another location. Remove it
  unlink($dst);
  if (not internal_sed($src, $dst, 0, $patchRef)) {
    error('Unable to copy the source file ' . $src . ' to the destination file ' . $dst . '.' . "\n\n");
  }
  db_add_file($dst, $flags);
  install_permission($src, $dst);
}

# mkdir() that reports errors
sub safe_mkdir {
  my $file = shift;

  if (mkdir($file, 0000) == 0) {
    error('Unable to create the directory ' . $file . '.' . "\n\n");
  }
}

# Remove trailing slashes in a dir path
sub dir_remove_trailing_slashes {
  my $path = shift;

  for(;;) {
    my $len;
    my $pos;

    $len = length($path);
    if ($len < 2) {
      # Could be '/' or any other character. Ok.
      return $path;
    }

    $pos = rindex($path, '/');
    if ($pos != $len - 1) {
      # No trailing slash
      return $path;
    }

    # Remove the trailing slash
    $path = substr($path, 0, $len - 1)
  }
}


# Create a hierarchy of directories with permission 0755
# flags:
#  0x1 write this directory creation in the installer database
# Return 1 if the directory existed before
sub create_dir {
  my $dir = shift;
  my $flags = shift;

  if (-d $dir) {
    return 1;
  }

  if (index($dir, '/') != -1) {
    create_dir(internal_dirname($dir), $flags);
  }
  safe_mkdir($dir);
  if ($flags & 0x1) {
    db_add_dir($dir);
  }
  safe_chmod(0755, $dir);
  return 0;
}

# Get a valid non-persistent answer to a question
# Use this when the answer shouldn't be stored in the database
sub get_answer {
  my $msg = shift;
  my $type = shift;
  my $default = shift;
  my $answer;

  if (not defined($gAnswerSize{$type})) {
    die 'get_answer(): type ' . $type . ' not implemented :(' . "\n\n";
  }
  for (;;) {
    $answer = check_answer(query($msg, $default, $gAnswerSize{$type}), $type, 'user');
    if (not ($answer eq '')) {
      return $answer;
    }
    if ($gOption{'default'} == 1) {
      error('Invalid default answer!' . "\n");
    }
  }
}

# Get a valid persistent answer to a question
# Use this when you want an answer to be stored in the database
sub get_persistent_answer {
  my $msg = shift;
  my $id = shift;
  my $type = shift;
  my $default = shift;
  my $isdefault = shift;
  my $answer;

  if (defined($gDBAnswer{$id}) && !defined($isdefault) ) {
    # There is a previous answer in the database
    $answer = check_answer($gDBAnswer{$id}, $type, 'db');
    if (not ($answer eq '')) {
      # The previous answer is valid. Make it the default value
      $default = $answer;
    }
  }

  $answer = get_answer($msg, $type, $default);
  db_add_answer($id, $answer);
  return $answer;
}

# Find a suitable backup name and backup a file
sub backup_file {
  my $file = shift;
  my $i;

  for ($i = 0; $i < 100; $i++) {
    if (not file_name_exist($file . '.old.' . $i)) {
      my %patch;

      undef %patch;
      if (internal_sed($file, $file . '.old.' . $i, 0, \%patch)) {
         print wrap('File ' . $file . ' is backed up to ' . $file .
         '.old.' . $i . '.' . "\n\n", 0);
      } else {
         print STDERR wrap('Unable to backup the file ' . $file .
         ' to ' . $file . '.old.' . $i .'.' . "\n\n", 0);
      }
      return;
    }
  }

   print STDERR wrap('Unable to backup the file ' . $file .
   '. You have too many backups files. They are files of the form ' .
   $file . '.old.N, where N is a number. Please delete some of them.' . "\n\n", 0);
}

# Uninstall a file previously installed by us
sub uninstall_file {
  my $file = shift;

  if (not db_file_in($file)) {
    # Not installed by this program
    return;
  }

  if (file_name_exist($file)) {
    # If this file is a config file and already exists or is modified,
    # leave it in place to save the users' modifications.
    if (defined($gDBConfig{$file}) && defined($gDBUserModified{$file})) {
      db_remove_file($file);
      return;
    }
    if (db_file_ts($file)) {
      my @statbuf;

      @statbuf = stat($file);
      if (defined($statbuf[9])) {
        if (db_file_ts($file) != $statbuf[9]) {
          # Modified since this program installed it
          if (defined($gDBConfig{$file})) {
            # Because config files need to survive the install and uninstall
            # process.
            $gDBUserModified{$file} = 'modified';
            db_remove_file($file);
            return;
          } else {
            backup_file($file);
          }
        }
      } else {
        print STDERR wrap('Unable to get the last modification timestamp of '
                          . 'the file ' . $file . '.' . "\n\n", 0);
      }
    }

    if (not unlink($file)) {
      error('Unable to remove the file "' . $file . '".' . "\n");
    } else {
      db_remove_file($file);
    }

  } elsif (vmware_product() ne 'acevm') {
    print wrap('This program previously created the file ' . $file . ', and '
               . 'was about to remove it.  Somebody else apparently did it '
               . 'already.' . "\n\n", 0);
    db_remove_file($file);
  }
}

# Uninstall a directory previously installed by us
sub uninstall_dir {
  my $dir = shift;
  my $force = shift;

  if (not db_dir_in($dir)) {
    # Not installed by this program
    return;
  }

  if (-d $dir) {
    if ($force eq '1') {
      system(shell_string($gHelper{'rm'}) . ' -rf ' . shell_string($dir));
    } elsif (not rmdir($dir)) {
      print wrap('This program previously created the directory ' . $dir
                 . ', and was about to remove it. Since there are files in '
                 . 'that directory that this program did not create, it will '
                 . 'not be removed.' . "\n\n", 0);
      if (   defined($ENV{'VMWARE_DEBUG'})
          && ($ENV{'VMWARE_DEBUG'} eq 'yes')) {
        system('ls -AlR ' . shell_string($dir));
      }
    }
  } elsif (vmware_product() ne 'acevm') {
    print wrap('This program previously created the directory ' . $dir
               . ', and was about to remove it. Somebody else apparently did '
               . 'it already.' . "\n\n", 0);
  }

  db_remove_dir($dir);
}

# Return the version of VMware
sub vmware_version {
  my $buildNr;

  $buildNr = '5.1.4 build-2248791';
  return remove_whitespaces($buildNr);
}

# Check the validity of an answer whose type is yesno
# Return a clean answer if valid, or ''
sub check_answer_yesno {
  my $answer = shift;
  my $source = shift;

  if (lc($answer) =~ /^y(es)?$/) {
    return 'yes';
  }

  if (lc($answer) =~ /^n(o)?$/) {
    return 'no';
  }

  if ($source eq 'user') {
    print wrap('The answer "' . $answer . '" is invalid. It must be one of "y" or "n".' . "\n\n", 0);
  }
  return '';
}
$gAnswerSize{'yesno'} = 3;
$gCheckAnswerFct{'yesno'} = \&check_answer_yesno;

# Check the validity of an answer based on its type
# Return a clean answer if valid, or ''
sub check_answer {
  my $answer = shift;
  my $type = shift;
  my $source = shift;

  if (not defined($gCheckAnswerFct{$type})) {
    die 'check_answer(): type ' . $type . ' not implemented :(' . "\n\n";
  }
  return &{$gCheckAnswerFct{$type}}($answer, $source);
}

# END OF THE LIBRARY FUNCTIONS

# Emulate a simplified basename program
sub internal_basename {
  return substr($_[0], rindex($_[0], '/') + 1);
}

# Set the name of the main /etc/vmware* directory.
sub initialize_globals {
  my $dirname = shift;

  if (vmware_product() eq 'api') {
    $gRegistryDir = '/etc/vmware-api';
    $gUninstallerFileName = 'vmware-uninstall-api.pl';
    $gConfigurator = 'vmware-config-api.pl';
  } elsif (vmware_product() eq 'acevm') {
    %gManifest = acevm_parse_manifest($dirname . '/' . $cManifestFilename);
    $gRegistryDir = $dirname;
    $gUninstallerFileName = 'vmware-uninstall-ace.pl';
    $gACEVMUpdate = (defined $gManifest{'update'}) && ($gManifest{'update'} == 1);
    $gPlayerBundle = 'VMware-Player.' . (is64BitUserLand() ? 'x86_64' : 'i386') .
                     '.bundle';
    $gConfigFile = '/etc/vmware/config';
  } elsif (vmware_product() eq 'tools-for-linux' ||
           vmware_product() eq 'tools-for-freebsd' ||
           vmware_product() eq 'tools-for-solaris') {
    $gRegistryDir = '/etc/vmware-tools';
    $gUninstallerFileName = 'vmware-uninstall-tools.pl';
    $gConfigurator = 'vmware-config-tools.pl';
  } elsif (vmware_product() eq 'vix') {
    $gRegistryDir = '/etc/vmware-vix';
    $gUninstallerFileName = 'vmware-uninstall-vix.pl';
    $gConfigurator = 'vmware-config-vix.pl';
    $gConfigFile = '/etc/vmware/config';
  } elsif (vmware_product() eq 'vix-disklib') {
    $gRegistryDir = '/etc/vmware-vix-disklib';
    $gUninstallerFileName = 'vmware-uninstall-vix-disklib.pl';
    $gConfigurator = 'vmware-config-vix-disklib.pl';
  } elsif (vmware_product() eq 'nvdk') {
    $gRegistryDir = '/etc/vmware-nvdk';
    $gUninstallerFileName = 'vmware-uninstall-nvdk.pl';
    $gConfigurator = 'vmware-config-nvdk.pl';
  } else {
    $gRegistryDir = '/etc/vmware';
    $gUninstallerFileName = 'vmware-uninstall.pl';
    $gConfigurator = 'vmware-config.pl';
  }
  $gStateDir = $gRegistryDir . '/state';
  $gInstallerMainDB = $gRegistryDir . '/locations';
  $gInstallerObject = $gRegistryDir . '/installer.sh';
  $gConfFlag = $gRegistryDir . '/not_configured';

  $gOption{'default'} = 0;
  $gOption{'nested'} = 0;
  $gOption{'upgrade'} = 0;
  $gOption{'ws-upgrade'} = 0;
  $gOption{'eula_agreed'} = 0;
  $gOption{'create_shortcuts'} = 1;

  if (defined $gConfigFile) {
      load_config();
  }
}

sub load_config() {
    $gConfig = new VMware::Config;
    $gConfig->readin($gConfigFile);
}

# Set up the location of external helpers
sub initialize_external_helpers {
  my $program;
  my @programList;

  if (not defined($gHelper{'more'})) {
    $gHelper{'more'} = '';
    if (defined($ENV{'PAGER'})) {
      my @tokens;

      # The environment variable sometimes contains the pager name _followed by
      # a few command line options_.
      #
      # Isolate the program name (we are certain it does not contain a
      # whitespace) before dealing with it.
      @tokens = split(' ', $ENV{'PAGER'});
      $tokens[0] = DoesBinaryExist_Prompt($tokens[0]);
      if (not ($tokens[0] eq '')) {
        # Whichever PAGER the user has, we want them to have the same
        # behavior, that is automatically exit the first time it reaches
        # end-of-file.
        # This is the behavior of `more', regardless of the command line
        # options. If `less' is used, however, the option '-E' should be
        # specified (see bug 254808).
        if ($tokens[0] eq internal_which('less')) {
           push(@tokens,'-E');
        }
        $gHelper{'more'} = join(' ', @tokens); # This is _already_ a shell string
      }
    }
    if ($gHelper{'more'} eq '') {
      $gHelper{'more'} = DoesBinaryExist_Prompt('more');
      if ($gHelper{'more'} eq '') {
        error('Unable to continue.' . "\n\n");
      }
      $gHelper{'more'} = shell_string($gHelper{'more'}); # Save it as a shell string
    }
  }

  if (vmware_product() eq 'tools-for-linux') {
    @programList = ('tar', 'sed', 'rm', 'lsmod', 'umount', 'mv',
                    'uname', 'mount', 'du', 'df', 'depmod', 'pidof',
		    'modprobe', 'rmmod', 'grep');
  } elsif (vmware_product() eq 'tools-for-freebsd') {
    @programList = ('tar', 'sed', 'rm', 'kldstat', 'umount',
                    'mv', 'uname', 'mount', 'du', 'df', 'kldload', 'kldunload');
  } elsif (vmware_product() eq 'tools-for-solaris') {
    @programList = ('tar', 'sed', 'rm', 'add_drv', 'rem_drv',
                    'modload', 'modunload', 'umount', 'mv', 'uname',
                    'mount', 'cat', 'update_drv', 'grep', 'gunzip',
                    'gzip', 'du', 'df', 'isainfo');
  } elsif (vmware_product() eq 'acevm') {
    @programList = ('tar', 'sed', 'rm', 'rmdir', 'mv', 'ps', 'du', 'df', 'mkdir',
		    'cp', 'chown');
  } elsif (vmware_product() eq 'vix') {
    @programList = ('tar', 'sed', 'rm', 'mv', 'ps', 'du', 'df', 'cp');
  } elsif (vmware_product() eq 'vix-disklib') {
    @programList = ('tar', 'sed', 'rm', 'rm', 'mv', 'ps', 'du', 'df', 'ldd');
  } elsif (vmware_product() eq 'nvdk') {
    @programList = ('tar', 'sed', 'rm', 'rm', 'mv', 'ps', 'du', 'df', 'ldd');
  } else {
    @programList = ('tar', 'sed', 'rm', 'killall', 'lsmod', 'umount', 'mv',
                    'uname', 'mount', 'du', 'df', 'depmod', 'pidof');
  }

  foreach $program (@programList) {
    if (not defined($gHelper{$program})) {
      $gHelper{$program} = DoesBinaryExist_Prompt($program);
      if ($gHelper{$program} eq '') {
        error('Unable to continue.' . "\n\n");
      }
    }
  }

  # Used for removing links that were not added as files to the database.
  $gHelper{'insserv'} = internal_which('insserv');
  $gHelper{'chkconfig'} = internal_which('chkconfig');
  $gHelper{'update-rc.d'} = internal_which('update-rc.d');
}

# Check the validity of an answer whose type is dirpath
# Return a clean answer if valid, or ''
sub check_answer_dirpath {
  my $answer = shift;
  my $source = shift;

  $answer = dir_remove_trailing_slashes($answer);

  if (substr($answer, 0, 1) ne '/') {
      print wrap('The path "' . $answer . '" is a relative path. Please enter '
		 . 'an absolute path.' . "\n\n", 0);
      return '';
  }

  if (-d $answer) {
    # The path is an existing directory
    return $answer;
  }

  # The path is not a directory
  if (file_name_exist($answer)) {
    if ($source eq 'user') {
      print wrap('The path "' . $answer . '" exists, but is not a directory.'
                 . "\n\n", 0);
    }
    return '';
  }

  # The path does not exist
  if ($source eq 'user') {
    return (get_answer('The path "' . $answer . '" does not exist currently. '
                       . 'This program is going to create it, including needed '
                       . 'parent directories. Is this what you want?',
                       'yesno', 'yes') eq 'yes') ? $answer : '';
  } else {
    return $answer;
  }
}
$gAnswerSize{'dirpath'} = 20;
$gCheckAnswerFct{'dirpath'} = \&check_answer_dirpath;

# Check the validity of an answer whose type is existdirpath
# Return a clean answer if valid, or ''
sub check_answer_existdirpath {
  my $answer = shift;
  my $source = shift;

  $answer = dir_remove_trailing_slashes($answer);

  if (substr($answer, 0, 1) ne '/') {
      print wrap('The path "' . $answer . '" is a relative path. Please enter '
		 . 'an absolute path.' . "\n\n", 0);
      return '';
  }

  if (-d $answer) {
    # The path is an existing directory
    return $answer;
  }

  # The path is not a directory
  if (file_name_exist($answer)) {
    if ($source eq 'user') {
      print wrap('The path "' . $answer . '" exists, but is not a directory.'
		 . "\n\n", 0);
    }
  } else {
    if ($source eq 'user') {
      print wrap('The path "' . $answer . '" is not an existing directory.'
		 . "\n\n", 0);
    }
  }
  return '';
}
$gAnswerSize{'existdirpath'} = 20;
$gCheckAnswerFct{'existdirpath'} = \&check_answer_existdirpath;

# Check the validity of an answer whose type is initdirpath
# Return a clean answer if valid, or ''
sub check_answer_initdirpath {
  my $answer = shift;
  my $source = shift;
  my $testdir;
  my @rcDirList;

  $answer = dir_remove_trailing_slashes($answer);

  if (not (-d $answer)) {
    if ($source eq 'user') {
      print wrap('The path "' . $answer . '" is not an existing directory.' . "\n\n", 0);
    }
    return '';
  }

  if (vmware_product() eq 'tools-for-solaris') {
    @rcDirList = ('rc0.d', 'rc1.d', 'rc2.d', 'rc3.d');
  } else {
    @rcDirList = ('rc0.d', 'rc1.d', 'rc2.d', 'rc3.d', 'rc4.d', 'rc5.d', 'rc6.d');
  }

  foreach $testdir (@rcDirList) {
    if (not (-d $answer . '/' . $testdir)) {
      if ($source eq 'user') {
         print wrap('The path "' . $answer . '" is a directory which does not contain a ' .
         $testdir . ' directory.' . "\n\n", 0);
      }
      return '';
    }
  }

  return $answer;
}
$gAnswerSize{'initdirpath'} = 15;
$gCheckAnswerFct{'initdirpath'} = \&check_answer_initdirpath;

# Check the validity of an answer whose type is initscriptsdirpath
# Return a clean answer if valid, or ''
sub check_answer_initscriptsdirpath {
  my $answer = shift;
  my $source = shift;

  $answer = dir_remove_trailing_slashes($answer);

  if (not (-d $answer)) {
    if ($source eq 'user') {
      print wrap('The path "' . $answer . '" is not an existing directory.' . "\n\n", 0);
    }
    return '';
  }

  return $answer;
}
$gAnswerSize{'initscriptsdirpath'} = 15;
$gCheckAnswerFct{'initscriptsdirpath'} = \&check_answer_initscriptsdirpath;

# Check the validity of an answer whose type is authdport
# Return a clean answer if valid, or ''
sub check_answer_authdport {
  my $answer = shift;
  my $source = shift;

  if (($answer =~ /^\d+$/) && ($answer > 0) && ($answer < 65536)) {
    return $answer;
  }
  if ($source eq 'user') {
    print wrap('The answer '. $answer . ' is invalid. Please enter a valid '
               . 'port number in the range 1 to 65535.' . "\n\n", 0);
  }
  return '';
}

$gAnswerSize{'authdport'} = 5;
$gCheckAnswerFct{'authdport'} = \&check_answer_authdport;

# Check the validity of an answer whose type is username
# Return a clean answer if valid, or ''
sub check_answer_username {
  my $answer = shift;
  my $source = shift;

  my ($name, $passwd, $uid, $gid) = getpwnam($answer);
  if (!defined $name) {
    print wrap('The answer '. $answer . ' is invalid. Please enter a valid '
	       . 'user on this system.' . "\n\n", 0);
    return '';
  }
  return $answer;
}

$gAnswerSize{'username'} = 8;
$gCheckAnswerFct{'username'} = \&check_answer_username;

# Install one symbolic link
sub install_symlink {
  my $to = shift;
  my $name = shift;

  uninstall_file($name);
  if (file_check_exist($name)) {
    return;
  }
  # The file could be a symlink to another location.  Remove it
  unlink($name);
  if (not symlink($to, $name)) {
    error('Unable to create symbolic link "' . $name . '" pointing to file "'
          . $to . '".' . "\n\n");
  }
  db_add_file($name, 0);
}

# Install one directory (recursively)
# flags are forwarded to install_file calls and recursive install_dir calls
sub install_dir {
  my $src_dir = shift;
  my $dst_dir = shift;
  my $patchRef = shift;
  my $flags = shift;
  my $is_suid_dir;
  if (@_ < 1) {
    $is_suid_dir=0;
  } else {
    $is_suid_dir=shift;
  }
  my $file;
  my $dir_existed = create_dir($dst_dir, $flags);

  if ($dir_existed) {
    my @statbuf;

    @statbuf = stat($dst_dir);
    if (not (defined($statbuf[2]))) {
      error('Unable to get the access rights of destination directory "' . $dst_dir . '".' . "\n\n");
    }

    # Was bug 15880
    if (   ($statbuf[2] & 0555) != 0555
        && get_answer('Current access permissions on directory "' . $dst_dir
                      . '" will prevent some users from using '
                      . vmware_product_name()
                      . '. Do you want to set those permissions properly?',
                      'yesno', 'yes') eq 'yes') {
      safe_chmod(($statbuf[2] & 07777) | 0555, $dst_dir);
    }
  } else {
    install_permission($src_dir, $dst_dir);
  }

  if ($is_suid_dir)
  {
    # Here is where we check (if necessary) for file ownership in this folder to actually "work"
    # This is due to the fact that if the destdir is on a squash_root nfs mount, things fail miserably
    my $tmpfilenam = $dst_dir . '/' . 'vmware_temp_'.$$;
    if (not open(TESTFILE, '>' . $tmpfilenam)) {
      error('Unable to write into ' . $dst_dir . "\n\n");
    }
    print TESTFILE 'garbage';
    close(TESTFILE);
    safe_chmod(04755, $tmpfilenam);
    my @statbuf;
    @statbuf = stat($tmpfilenam);
    if ($statbuf[4]!=0 or ($statbuf[2] & 07000)!=04000) {
      if (! $dir_existed)
      {
        # Remove the directory if we had to create it.
        # XXX This could leave a dangling hierarhcy
        # but that is a more complicated issue.
        rmdir($dst_dir);
      }
      # Ask the user what to do, default to 'no'(abort install) to avoid infinite loop on --default.
      my $answer = get_answer('The installer was unable to set-uid to root on files in ' . $dst_dir . '.  Would you like ' .
                              'to select a different directory?  If you select no, the install will be aborted.','yesno','no');
      if ($answer eq 'no')
      {
        # We have to clean up the ugliness before we abort.
        uninstall();
        error ('User aborted install.');
      }
      return 1;
    }
    unlink($tmpfilenam);
  }

  foreach $file (internal_ls($src_dir)) {
    my $src_loc = $src_dir . '/' . $file;
    my $dst_loc = $dst_dir . '/' . $file;

    if (-l $src_loc) {
      install_symlink(readlink($src_loc), $dst_loc);
    } elsif (-d $src_loc) {
      install_dir($src_loc, $dst_loc, $patchRef, $flags);
    } else {
      install_file($src_loc, $dst_loc, $patchRef, $flags);
    }
  }
  return 0;
}

# Display the end-user license agreement
sub show_EULA {
  if ((not defined($gDBAnswer{'EULA_AGREED'}))
      || (db_get_answer('EULA_AGREED') eq 'no')) {
    query('You must read and accept the ' . vmware_product_name()
          . ' End User License Agreement to continue.'
          .  "\n" . 'Press enter to display it.', '', 0);

    open(EULA, './doc/EULA') ||
      error("$0: can't open EULA file: $!\n");

    my $origRecordSeparator = $/;
    undef $/;

    my $eula = <EULA>;
    close(EULA);

    $/ = $origRecordSeparator;

    $eula =~ s/(.{50,76})\s/$1\n/g;

    # Trap the PIPE signal to avoid broken pipe errors on RHEL4 U4.
    local $SIG{PIPE} = sub {};

    open(PAGER, '| ' . $gHelper{'more'}) ||
      error("$0: can't open $gHelper{'more'}: $!\n");
    print PAGER $eula . "\n";
    close(PAGER);

    print "\n";

    # Make sure there is no default answer here
    if (get_answer('Do you accept? (yes/no)', 'yesno', '') eq 'no') {
      print wrap('Please try again when you are ready to accept.' . "\n\n", 0);
      uninstall_file($gInstallerMainDB);
      exit 1;
    }
    print wrap('Thank you.' . "\n\n", 0);
  }
}

# XXX This code is mostly duplicated from the main server installer.
sub build_perl_api {
  my $control;
  my $build_dir;
  my $program;
  my $cTmpDirPrefix = 'api-config';

  foreach $program ('tar', 'perl', 'make', 'touch') {
    if (not defined($gHelper{$program})) {
      $gHelper{$program} = DoesBinaryExist_Prompt($program);
      if ($gHelper{$program} eq '') {
        error('Unable to continue.' . "\n\n");
      }
    }
  }

  print wrap('Installing the VMware VmPerl Scripting API.' . "\n", 0);

  $control = './control.tar';
  if (not (file_name_exist($control))) {
    error('Unable to find the VMware VmPerl Scripting API. '
          . 'You may want to re-install ' . vmware_product_name()
          . '.' .  "\n\n");
  }

  $build_dir = make_tmp_dir($cTmpDirPrefix);

  if (system(shell_string($gHelper{'tar'}) . ' -C ' . shell_string($build_dir) . ' -xopf ' .
             shell_string($control))) {
    print wrap('Unable to untar the "' . $control . '" file in the "' . $build_dir .
               '" directory.' . "\n\n", 0);
    error('');
  }

  if (system('cd ' . shell_string($build_dir . '/control-only') . ' && ' .
             shell_string($gHelper{'perl'}) . ' Makefile.PL > make.log 2>&1')) {
    print wrap('Unable to create the VMware VmPerl Scripting API makefile.' . "\n\n", 0);

    # Look for the header files needed to build the Perl module.  If we don't
    # find them, suggest to the user how they can install the files.
    if (open(PERLINC, shell_string($gHelper{'perl'}) . ' -MExtUtils::Embed ' .
             '-e perl_inc |')) {
      my $inc = <PERLINC>;
      close(PERLINC);
      $inc =~ s/\s*-I//;
      if (not file_name_exist($inc . '/perl.h')) {
        print wrap('Could not find necessary components to build the '
                   . 'VMware VmPerl Scripting API.  Look in your Linux '
                   . 'distribution to see if there is a perl-devel package.  '
                   . 'Install that package if it exists and then re-run this '
                   . 'installation program.' . "\n\n", 0);
      }
    }
    return(perl_config_fail($build_dir));
  }

  print wrap("\n", 0);
  print wrap('Building the VMware VmPerl Scripting API.' . "\n\n", 0);

  # Make sure we have a compiler available
  if (get_cc() eq '') {
    print wrap('Unable to install the VMware VmPerl Scripting API.', 0);
    print wrap('A C compiler is required to install the API.' . "\n\n",  0);
    remove_tmp_dir($build_dir);
    return;
  }

  # We touch all our files in case the system clock is set to the past.  Make will get confused and
  # delete our shipped .o file(s).
  # More code duplication from pkg_mgr.pl (really, really bad)
  system(shell_string($gHelper{'touch'}) . ' '
         . shell_string($build_dir . '/control-only') . '/* >>'
         . shell_string($build_dir . '/control-only') . '/make.log 2>&1');

  if (system(shell_string($gHelper{'make'}) . ' -C '
             . shell_string($build_dir . '/control-only') . ' '
             . shell_string('CC=' . $gHelper{'gcc'}) . ' '
             . ' >>' . shell_string($build_dir . '/control-only') . '/make.log 2>&1')) {
    print wrap('Unable to compile the VMware VmPerl Scripting API.' . "\n\n", 0);
    return(perl_config_fail($build_dir));
  }

  print wrap("Installing the VMware VmPerl Scripting API.\n\n", 0);


  # XXX This is deeply broken: we let a third party tool install a file without
  #     adding it to our installer database.  This file will never get
  #     uninstalled by our uninstaller
  if (system(shell_string($gHelper{'make'}) . ' -C '
             . shell_string($build_dir . '/control-only') . ' '
             . shell_string('CC=' . $gHelper{'gcc'}) . ' '
             . ' install >>' . shell_string($build_dir . '/control-only')
             . '/make.log 2>&1')) {
    print wrap('Unable to install the VMware VmPerl Scripting API.' . "\n\n", 0);
    return(perl_config_fail($build_dir));
  }

  print wrap('The installation of the VMware VmPerl Scripting API succeeded.' . "\n\n", 0);
  remove_tmp_dir($build_dir);
}

# XXX Mostly duplicated from the main server installer.
# Common error message when we can't compile or install our perl modules
sub perl_config_fail {
  my $dir = shift;

  print wrap('********' . "\n". 'The VMware VmPerl Scripting API was not '
             . 'installed.  Errors encountered during compilation and '
             . 'installation of the module can be found here: ' . $dir
             . "\n\n" . 'You will not be able to use the "vmware-cmd" '
             . 'program.' . "\n\n" . 'Errors can be found in the log file: '
             . shell_string($dir . '/control-only/make.log')
             . "\n" . '********' . "\n\n", 0);
  error('');
}

# Configures gtk.  Returns 1 on success, 0 on failure.
sub configure_gtk2 {
   if (vmware_product() eq 'tools-for-linux') {
      # Setup the environment to match what configure-gtk expects,
      # as too the wrappers for vmware-user and vmware-toolbox.
      my $is64BitUserland = is64BitUserLand();
      my $libdir = db_get_answer('LIBDIR');
      my $libbindir = $libdir . ($is64BitUserland ? '/bin64' : '/bin32');
      my $libsbindir = $libdir . ($is64BitUserland ? '/sbin64' : '/sbin32');
      my $liblibdir = $libdir . ($is64BitUserland ? '/lib64' : '/lib32');
       # Generic spots for the vmware-user/toolbox wrapper
       # to access so it won't need to know lib32, etc.
       install_symlink($liblibdir, $libdir . "/lib");
       install_symlink($libbindir, $libdir . "/bin");
       install_symlink($libsbindir, $libdir . "/sbin");
       install_symlink($liblibdir . "/libconf", $libdir . "/libconf");
   }
   return system(sprintf "%s/bin/configure-gtk.sh", db_get_answer("LIBDIR")) == 0;
}

# Handle the installation and configuration of vmware's perl module
sub install_perl_api {
  my $rootdir;
  my $answer;
  my $mandir;
  my $docdir;
  my %patch;

  undef %patch;
  install_dir('./etc', $gRegistryDir, \%patch, 0x1);

  $rootdir = '/usr';

  $answer = spacechk_answer('In which directory do you want to install '
                            . 'the executable files?', 'dirpath',
                            $rootdir . '/bin', './bin', 'BINDIR');
  undef %patch;
  install_dir('./bin', $answer, \%patch, 0x1);
  $gIsUninstallerInstalled = 1;

  $rootdir = internal_dirname($answer);
  # Don't display a double slash (was bug 14109)
  if ($rootdir eq '/') {
    $rootdir = '';
  }

  # We don't use default answers here because once the user has
  # selected the root directory, we can give him better default answers than
  # his/her previous answers but we do want to make sure the directory
  # chosen has enough space to hold the data.

  $answer = spacechk_answer('In which directory do you want to install '
                            . 'the library files?', 'dirpath',
                            $rootdir . '/lib/vmware-api', './lib');
  db_add_answer('LIBDIR', $answer);
  undef %patch;
  install_dir('./lib', $answer, \%patch, 0x1);

  $docdir = $rootdir . '/share/doc';
  if (not (-d $docdir)) {
    $docdir = $rootdir . '/doc';
  }
  $answer = spacechk_answer('In which directory do you want to install the '
                            . 'documentation files?', 'dirpath',
                            $docdir . '/vmware-api', './doc');
  db_add_answer('DOCDIR', $answer);
  undef %patch;
  install_dir('./doc', $answer, \%patch, 0x1);

  build_perl_api();
}

# Look for the location of the vmware-acetool binary. We search /etc/vmware/locations
# for it and return the path or '' if we can't find it.
sub acevm_find_acetool  {
  if (!defined $gConfig) {
    return '';
  }

  my $path = $gConfig->get('bindir') .  "/vmware-acetool";

  return file_name_exist($path) ? $path : '';
}


# returns true if the included build player is newer
sub acevm_included_player_newer {
  return 2248791 gt int($gConfig->get('product.buildNumber', ''));
}

# untar and install vmware-player.
sub acevm_install_vmplayer {
  my $ret;

  if (!-e $gPlayerBundle) {
    error('This ACE package does not contain a VMware Player installer. You must ' .
	  'install VMware Player before installing this package.' . "\n\n");
  } elsif (!is_root()) {
    error('This program can install VMware Player installer for you, but you must ' .
	  'be a system administrator. Try running this setup program with sudo or ' .
	  'contact your system administrator for help.' . "\n\n");
  } else {
    my $cmd;
    my $tmpDir;

    print wrap("Installing VMware Player\n\n", 0);

    # TODO: Need a way to inhibit creation of shortcuts.  env variable
    # probably.
    my @args = ("sh", "$gPlayerBundle");
    return system("sh $gPlayerBundle") == 0;
  }
}

# Open and parse the manifest file. This file contains little bits of information
# we need to install and ACE.
sub acevm_parse_manifest {
  my $path = shift;
  my $line;
  my %ret;

  if (not open(MANIFEST, '<' . $path)) {
    error('Unable to open the MANIFEST file in read-mode.' . "\n\n");
  }
  while ($line = <MANIFEST>) {
    # Strip carriage returns, if they exist.
    $line =~ s/\r//g;
    $line =~ m/^(.+)=(.+)$/;
    $ret{$1} = $2;
  }
  close MANIFEST;
  return %ret;
}

# Get the install (non-update) directory for this ACE package. If the directory
# contains a VMX file, make sure this package does not. Finally, there must be enough
# space to hold the package.
sub acevm_get_dir {
  my $rootdir = shift;
  my $answer = undef;

  while (!defined($answer)) {
    $answer = get_answer("In which directory do you want to install this ACE?",
			 'dirpath', $rootdir, 0);
    if (acevm_find_vmx($answer) ne '' && $gManifest{'hasVM'}) {
      print wrap("There is another ACE already installed in '" . $answer .
		 "'. Please choose another directory.\n\n", 0);
      $answer = '';
    } else {
      if (!check_dir_writeable($answer)) {
	print wrap("No permission to write to directory '" . $answer .
		   "'. Please choose another directory.\n\n", 0);
	$answer = '';
      }
      if (check_disk_space('.', internal_dirname($answer)) < 0) {
	print wrap("There is not enough space to install this ACE in '" .
		   $answer . "'. Please choose another directory.\n\n", 0);
	$answer = '';
      }
    }
    if ($answer eq '' && !$gOption{'default'}) {
      undef $answer;
    }
  }
  return $answer;
}

# Return the config filename. Usually, the MANIFEST file has this for us. If it
# doesn't we'll try to construct it from the acename entry.
sub acevm_get_config_filename {
  return (defined $gManifest{'configFile'} ? $gManifest{'configFile'} :
                                              $gManifest{'acename'}) .
          '.vmx';
}

# Get the installed directory for an already installed ACE package that we will update.
# The directory must exist already and there must be enough space to hold the update
# content.
sub acevm_get_updatedir {
  my $rootdir = shift;
  my $answer = undef;
  my $cfgFile;

  while (!defined($answer)) {
    $answer = get_answer('Which directory contains the ACE you want to update?',
			 'existdirpath', $rootdir, 0);
    if (($cfgFile = acevm_find_vmx($answer)) eq '') {
      print wrap("There is no ACE installed in '$answer'. ", 0);
      $answer = '';
    } elsif (!acevm_checkMasterID($cfgFile)) {
      print wrap("The ACE in '$answer' does not have the same ID as this " .
		 'ACE update package. ', 0);
      $answer = '';
    } elsif (check_disk_space('.', internal_dirname($answer)) < 0) {
      print wrap("There is not enough space to install this ACE update package in '" .
		 $answer . "'. ", 0);
      $answer = '';
    }
    if ($answer eq '' && !$gOption{'default'}) {
      undef $answer;
      print wrap('Please choose another directory.' . "\n\n", 0);
    }
  }
  return $answer;
}

# Uninstall host policies
sub acevm_uninstall_host_policies() {
  my $bindir = $gConfig->get('bindir');
  my $cmd = sprintf "%s --uninstall-host-policy > /dev/null",
               shell_string("$bindir/vmware-networks");
  return system($cmd) == 0;
}

# Does the package we're about to install have host.vmpl or host-update.vmpl?
sub acevm_package_has_host_policies  {
  return (file_name_exist('./VM/host.vmpl') ||
	  file_name_exist('./VM/host-update.vmpl'));
}

# Can we install host.vmpl? We will install our host.vmpl if:
# - There is no /etc/vmware-ace/host.vmpl installed
# - If there is a host.vmpl, is this an update? Specifically, the aceid of this
#   package matches the aceid of the package that installed the host.vmpl
sub acevm_can_install_host_policies {
  my $hostvmpl = "$gHostVmplDir/host.vmpl";
  my $ret;

  if (file_name_exist($hostvmpl)) {
    my $cmd = sprintf "%s checkMasterID %s %s > /dev/null 2>&1",
                 shell_string($gHelper{'vmware-acetool'}),
                 shell_string($hostvmpl),
                 shell_string($gManifest{'aceid'});
    $ret = system($cmd) == 0;
  } else {
    $ret = 1;
  }

  return $ret;
}

# Handle the installation and configuration of a packaged ACE vm.
# These are installed per user.
sub install_content_acevm {
  my %patch;

  # First, write BINDIR. It's the same directory as the one
  # containing $gInstallerMainDB.
  db_add_answer('BINDIR', $gRegistryDir);
  db_add_dir($gRegistryDir, 0x0);
  undef %patch;
  install_file("./vmware-install.pl", $gRegistryDir . '/' . $gUninstallerFileName,
	       \%patch, 0x0);
  undef %patch;
  install_file("./installer.sh", $gRegistryDir . '/installer.sh', \%patch, 0x0);
  undef %patch;
  install_file("./MANIFEST", $gRegistryDir . '/MANIFEST', \%patch, 0x0);
  $gIsUninstallerInstalled = 1;

  # copy VM to installPath
  install_dir("./VM", $gRegistryDir, \%patch, 0x0);

  if (acevm_package_has_host_policies()) {
      acevm_install_host_policies();
  }

  if ($gManifest{'hasVM'} == 1) {
    print wrap('Finalizing ACE... ', 0);
    my $ret = acevm_finalize();
    print wrap("\n", 0);
    if (!$ret) {
      print wrap("This ACE was not finalized correctly, undoing installation...\n\n", 0);
      system(shell_string("$gRegistryDir/$gUninstallerFileName"));
      error("Unable to finalize ACE, installation failed.\n\n")
    }
  }

  acevm_create_desktop_icon($gManifest{'acename'}, $gManifest{'aceid'}, $gRegistryDir .
                            '/VM/' . $gManifest{'configFile'});
}

# Handle an update to a packaged ACE vm.
# A matching ACE package must already have been installed
sub install_content_acevm_update {
  my %patch;

  # copy VM to installPath
  install_dir("./VM", $gRegistryDir, \%patch, 0x0);

  if (acevm_package_has_host_policies()) {
      acevm_install_host_policies();
  }
}

sub install_content_tools_etc_openvmcompat {
  my @files = (
   'vmware-tools-libraries.conf',
   'manifest.txt.shipped',
   'vmware-tools-prelink.conf',
   'installer.sh',
   'not_configured'
  );
  my $f;

  foreach $f (@files) {
    install_file('./etc/' . $f, $gRegistryDir . '/' . $f, undef, 0);
  }
}

# Install a host policy file, a ace.dat, maybe an an ace.crt, and restart
# vmware-netdetect
sub acevm_install_host_policies() {
  my %patch;
  my $update = '';
  my $hostVMPolicy = "$gHostVmplDir/host$update.vmpl";
  my $cmd;

  if (file_name_exist("$gRegistryDir/host.vmpl")) {
    if (not (-d $gHostVmplDir)) {
      safe_mkdir($gHostVmplDir);
      safe_chmod(0755, $gHostVmplDir);
    }

    if (file_name_exist("$gHostVmplDir/host.vmpl")) {
      $update = '-update';
    }

    undef %patch;
    unlink($hostVMPolicy);
    install_file("$gRegistryDir/host.vmpl", "$hostVMPolicy", \%patch, 0x0);
    uninstall_file("$gRegistryDir/host.vmpl");

    undef %patch;
    unlink("$gHostVmplDir/ace.dat");
    install_file("$gRegistryDir/ace.dat", "$gHostVmplDir/ace.dat", \%patch, 0x0);

    # If ace.crt exists, install it next to host policies. ace.crt
    # lives either in the VM directory or in the Resources directory.
    my $ace_crt_file = sprintf "$gRegistryDir/%s/ace.crt",
    ($gManifest{'hasVM'} ? '/ACE Resources' : '');

    if (file_name_exist($ace_crt_file)) {
      undef %patch;
      install_file($ace_crt_file, "$gHostVmplDir/ace.crt", \%patch, 0x0);
    }
  }

  # Setup NAT
  my $subnet;
  my $dhcp;
  my $result;
  $cmd = sprintf "%s configureNATSubnet %s 2> /dev/null",
           shell_string($gHelper{'vmware-acetool'}),
           shell_string($hostVMPolicy);
  open(CMD, $cmd . ' |');
  ($subnet, $dhcp) = <CMD>;
  $result = close(CMD);

  if (defined $dhcp) {
    chomp($dhcp);
    $dhcp = $dhcp eq "yes" ? 1 : 0;
  }

  defined $subnet && chomp($subnet);

  my $bindir = $gConfig->get('bindir');
  $cmd = sprintf "%s --install-host-policy%s > /dev/null",
                shell_string("$bindir/vmware-networks"),
                (defined $subnet && defined $dhcp) ? "=$subnet,$dhcp" : "";
  return system($cmd) == 0;
}

# Install the content of the tools tar package
sub install_content_tools {
  my $rootdir;
  my $answer;
  my %patch;
  my $mandir;
  my $docdir;
  my @upstartJobInfo;

  undef %patch;
  if ($open_vm_compat) {
    install_content_tools_etc_openvmcompat();
  } else {
    install_dir('./etc', $gRegistryDir, \%patch, 0x1);
  }

  if (defined($gOption{'prefix'})) {
    $rootdir = $gOption{'prefix'};
  } elsif (vmware_product() eq 'tools-for-freebsd') {
    $rootdir = '/usr/local';
  } elsif (vmware_product() eq 'tools-for-solaris') {
    $rootdir = '/usr';
  } else {
    $rootdir = '/usr';
  }
  $answer = spacechk_answer('In which directory do you want to '
                            . 'install the binary files?', 'dirpath',
                            $rootdir . '/bin', './bin', 'BINDIR');
  undef %patch;
  install_dir('./bin', $answer, \%patch, 0x1);

  $rootdir = internal_dirname($answer);
  # Don't display a double slash (was bug 14109)
  if ($rootdir eq '/') {
    $rootdir = '';
  }

  # Finds the location of the initscripts dir
  # As a side effect, sets INITSCRIPTSDIR in the locations database.
  $answer = get_initscriptsdir();

  if (vmware_product() eq 'tools-for-linux' &&
      (@upstartJobInfo = locate_upstart_jobinfo())) {
    my ($jobPath, $jobSuffix) = @upstartJobInfo;
    my $upstartJobFile = "$jobPath/vmware-tools$jobSuffix";

    # Step 1:  Install services script in $gRegistryDir.
    install_file($cStartupFileName, "$gRegistryDir/services.sh", undef, 0);
    # Step 2:  Install Upstart job.
    install_file("$cInstallerDir/upstart-job.conf", $upstartJobFile, undef, 0);
    db_add_answer('UPSTARTJOB', $upstartJobFile);
  } else {
    # install the service script.
    if (vmware_product() eq 'tools-for-freebsd') {
      $answer = get_answer('In which directory do you want to install the '
                           . 'startup script?', 'dirpath', $answer);
      create_dir($answer,0);
    }

    # We need to check whether or not the system has either insserv, or chkconfig,
    # or neither.  Depending on what we find, we will modify the patch variable
    # so that our startup script has only the info it needs.  This gets us around
    # the issue where RedHat tries (unsuccessfully) to use LSB info to determine where
    # our scripts need to start/stop.
    my $insserv = internal_which('insserv');
    my $chkconfig = internal_which('chkconfig');
    my $update_rc_dot_d = internal_which('update-rc.d');

    if ( "$update_rc_dot_d" ne "") {
      %patch = ('##VMWARE_INIT_INFO##' => "$cLSBInitInfo");
      db_add_answer('INIT_STYLE', 'update-rc.d');
    } elsif ( "$insserv" ne "") {
      %patch = ('##VMWARE_INIT_INFO##' => "$cLSBInitInfo");
      db_add_answer('INIT_STYLE', 'lsb');
    } elsif ("$chkconfig" ne '') {
      %patch = ('##VMWARE_INIT_INFO##' => "$cChkconfigInfo");
      db_add_answer('INIT_STYLE', 'chkconfig');
    } else {
      %patch = ('##VMWARE_INIT_INFO##' => "$cChkconfigInfo\n\n$cLSBInitInfo");
      db_add_answer('INIT_STYLE', 'custom');
    }
    install_file($cStartupFileName,
                 $answer . (vmware_product() eq 'tools-for-freebsd' ?
                            '/vmware-tools.sh' : '/vmware-tools'), \%patch, 0x1);
  }

  $gIsUninstallerInstalled = 1;

  # We don't use get_persistent_answer() here because once the user has
  # selected the root directory, we can give him better default answers than
  # his/her previous answers but we do want to make sure the directory
  # chosen has enough space to hold the data.

  $answer = get_answer('In which directory do you want to install '
                       . 'the daemon files?', 'dirpath', $rootdir . '/sbin');
  db_add_answer('SBINDIR', $answer);
  undef %patch;
  create_dir($answer, 0x1);

  $answer = spacechk_answer('In which directory do you want to install '
                            . 'the library files?', 'dirpath', $rootdir
                            . '/lib/vmware-tools', './lib');
  db_add_answer('LIBDIR', $answer);

  # Now that we know the LIBDIR, we need to add a rule to /etc/prelink.conf
  # to prevent it from toying with apploader or any of our apps.
  #
  # Note:  We have no choice but to fix this here because time is a factor.
  #        If we don't modify the config file here, prelink could be
  #        invoked by cron and would modify our binaries before config.pl
  #        is run.  Modifying the prelink.conf file here should prevent
  #        that from happening.
  if (vmware_product() eq 'tools-for-linux') {
    prelink_fix();
  }

  undef %patch;
  install_dir('./lib', $answer, \%patch, 0x1);

  # We don't yet maintain ownership and permissions metadata for all the
  # files we install.  For the timebeing until vmis obsoletes this code,
  # this will workaround the scenario of the install tarball being extracted
  # as a user, and thus the suid bit on vmware-user-suid-wrapper being
  # cleared before install.

  # Setuid root
  if (vmware_product() eq 'tools-for-freebsd') {
    safe_chmod(04555, $answer . '/bin32-63/vmware-user-suid-wrapper');
    safe_chmod(04555, $answer . '/bin64-63/vmware-user-suid-wrapper');
  } elsif (vmware_product() eq 'tools-for-solaris') {
    # note: for solaris, the amd64 version is a symlink to this i86 version
    safe_chmod(04555, $answer . '/bin/i86/vmware-user-suid-wrapper');
  } elsif (vmware_product() eq 'tools-for-linux') {
    safe_chmod(04555, $answer . '/bin32/vmware-user-suid-wrapper');
    safe_chmod(04555, $answer . '/bin64/vmware-user-suid-wrapper');
  }

  # Deal with hgfsmounter which is not suid anymore
  # .. and with vmblockmounter as well.
  if (vmware_product() eq 'tools-for-linux') {
    safe_chmod(0555, $answer . '/sbin32/vmware-hgfsmounter');
    safe_chmod(0555, $answer . '/sbin64/vmware-hgfsmounter');

    if ($open_vm_compat == 0) {
      # Handle vmware-hgfsmounter in a special manner so it will work with
      # SELinux.  See bug 527827.
      if (-d '/sbin') {
        my $sbinArch = (is64BitUserLand() ? '64' : '32');
        my $vmwSbinDir = join('/', $answer, 'sbin' . $sbinArch);
        my $vmwHgfsmntPath = "$vmwSbinDir/vmware-hgfsmounter";
        my $sbinHgfsmntPath = '/sbin/mount.vmhgfs';

        # Move vmware-hgfsmounter to /sbin and setup a link for
        # legacy purposes.  Also call restorecon for good measure.
        install_file($vmwHgfsmntPath, $sbinHgfsmntPath, \%patch, 0x1);
        unlink($vmwHgfsmntPath);
        db_remove_file($vmwHgfsmntPath);
        restorecon($sbinHgfsmntPath);
        install_symlink($sbinHgfsmntPath, $vmwHgfsmntPath);
      }
    }
  } elsif (vmware_product() eq 'tools-for-solaris') {
    safe_chmod(0555, $answer . '/sbin/i86/vmware-hgfsmounter');
    safe_chmod(0555, $answer . '/sbin/amd64/vmware-hgfsmounter');
    safe_chmod(0555, $answer . '/sbin/i86/vmware-vmblockmounter');
    safe_chmod(0555, $answer . '/sbin/amd64/vmware-vmblockmounter');
  } elsif (vmware_product() eq 'tools-for-freebsd') {
    safe_chmod(0555, $answer . '/sbin32-63/vmware-vmblockmounter');
    safe_chmod(0555, $answer . '/sbin64-63/vmware-vmblockmounter');
  }

  $docdir = $rootdir . '/share/doc';
  if (not (-d $docdir)) {
    $docdir = $rootdir . '/doc';
  }
  $answer = spacechk_answer('In which directory do you want to install the '
                            . 'documentation files?', 'dirpath', $docdir
                            . '/vmware-tools', './doc');
  db_add_answer('DOCDIR', $answer);
  undef %patch;
  install_dir('./doc', $answer, \%patch, 0x1);

  #
  # Modify vmware-user.desktop so that the Execute variable gets
  # a full path to the vmware-user binary instead of having to
  # rely on the PATH var being set correctly.
  #
  # See bug 368867 for details.  -astiegmann
  #
  my $execStr = 'Exec=' . db_get_answer('BINDIR') . '/vmware-user';
  my $filePath = $gRegistryDir . '/vmware-user.desktop';
  %patch = ('Exec=.*$' => $execStr);
  internal_sed ('./etc/vmware-user.desktop', $filePath, 0, \%patch);
}

sub uninstall_content_legacy_tools {
  my $OldInstallerDB = '/etc/vmware-tools/tools_log';
  my $OldInstallerDBOld = '/etc/vmware/tools_log';
  my $TmpMainDB = $gInstallerMainDB;
  my $File;
  my @Files;
  my $MovedFile;
  my $LinkedFile;
  my $answer;
  my $runlevel;

  # This is necessary for old installations of the tools
  # when /etc/vmware was one and unique dump for all the products
  if (-e $OldInstallerDBOld) {
    $OldInstallerDB = $OldInstallerDBOld;
  }
  if (!-e $OldInstallerDB) {
    # Old tools database not found, assume that the system is clean.
    return;
  }
  # Swap the db with the old one temporarely.
  $gInstallerMainDB = $OldInstallerDB;

  db_load();
  if (not open(INSTALLDB, '>>' . $gInstallerMainDB)) {
    error('Unable to open the tar installer database ' . $gInstallerMainDB
          . ' in write-mode.' . "\n\n");
  }

  $answer = get_answer('An old installation of the tools is detected. '
                       . 'Should this installation be removed ?',
                       'yesno', 'yes');
  if ($answer eq 'no') {
    error('');
  }

  # Stop the services
  foreach $File (keys %gDBFile) {
    if ($File =~ /\S+\/dualconf(\.sh)?$/) {
      system(shell_string($File) . ' stop');
      print "\n";
      last;
    }
  }
  # Remove the files
  foreach $File (keys %gDBFile) {
    if ($File !~ /\/tmp\S+/) {
      uninstall_file($File);
    }
  }
  # Remove the links
  foreach $LinkedFile (keys %gDBLink) {
    unlink $LinkedFile;
  }
  # At last, replace the original files.
  foreach $MovedFile (keys %gDBMove) {
    # XXX we do not have a timestamp for those files so we can't
    # know if the user changed it, so I back it up.
    if (-e $gDBMove{$MovedFile}) {
      backup_file($gDBMove{$MovedFile});
      unlink $gDBMove{$MovedFile};
    }
    if (-e $MovedFile) {
      if ($MovedFile =~ /\S+\.org/) {
        rename $MovedFile, $gDBMove{$MovedFile};
      } elsif ($gDBMove{$MovedFile} =~ /\.new$/) {
        # Nothing to do for /etc/rc and /etc/rc.shutdown
      } else {
        backup_file($MovedFile);
        unlink $MovedFile;
      }
    }
  }

  # Clean up the broken links.
  foreach $File (qw(/etc/modules.conf /etc/conf.modules /etc/XF86Config
                    /etc/X11/XF86Config /etc/X11/XF86Config-4)) {
    if ((-l $File) && (-e ($File . '.org'))) {
      unlink $File;
      rename $File . '.org', $File;
    }
  }

  get_initscriptsdir();
  $Files[0] = db_get_answer('INITSCRIPTSDIR') . '/vmmemctl';
  foreach $runlevel ('0', '1', '2', '3', '4', '5', '6', 'S', 's') {
    push @Files, db_get_answer('INITDIR') . '/rc' . $runlevel
                 . '.d/S99vmmemctl';
  }
  # Cleanup the files that aren't mentionned in the install database.
  foreach $File (@Files) {
    if (file_name_exist($File)) {
      unlink $File;
    }
  }

  db_save();
  unlink $gInstallerMainDB;

  if (direct_command('LANG=C ' .
                     shell_string(vmware_product() eq 'tools-for-freebsd' ?
                                  $gHelper{'kldstat'} : $gHelper{'lsmod'})) =~
                     /vmmemctl/) {
    print wrap('The uninstallation of legacy tools completed. '
             . 'Please restart this virtual machine to ensure that '
             . 'all the loaded components are removed from the memory and '
             . 'run this installer again to continue with the upgrade.'
             . "\n\n", 0);
    exit 0;
  }
  # Restore the original database file name in case we don't have
  # to reboot because of the loaded vmmemctl.
  $gInstallerMainDB = $TmpMainDB;
}

# Return GSX or ESX for server products, Workstation for ws
sub installed_vmware_version {
  my $vmware_version;
  my $vmware_version_string;

  if (not defined($gHelper{"vmware"})) {
    $gHelper{"vmware"} = DoesBinaryExist_Prompt("vmware");
    if ($gHelper{"vmware"} eq '') {
      error('Unable to continue.' . "\n\n");
    }
  }

  $vmware_version_string = direct_command(shell_string($gHelper{"vmware"})
                                          . ' -v 2>&1 < /dev/null');
  if ($vmware_version_string =~ /.*VMware\s*(\S+)\s*Server.*/) {
    $vmware_version = $1;
  } else {
    $vmware_version = "Workstation";
  }
  return $vmware_version;
}

#BEGIN UNINSTALLER SECTION
# Uninstaller section for old style MUI installer: Most of this code is
# directly copied over from the old installer
my %gConfData;

# Read the config vars to our internal array
sub readConfig {
  my $registryFile = shift;
  if (open(OLDCONFIG, $registryFile)) {
    # Populate our array with everthing from the conf file.
    while (<OLDCONFIG>) {
      m/^\s*(\S*)\s*=\s*(\S*)/;
      $gConfData{$1} = $2;
    }
    close(OLDCONFIG);
    return(1);
  }
  return(0);
}

# END UNINSTALLER SECTION
# Install the content of the tar package
sub install_content {
  my $rootdir;
  my $answer;
  my %patch;
  my $mandir;
  my $docdir;
  my $initdir;
  my $libdir;
  my $initscriptsdir;

  undef %patch;
  install_dir('./etc', $gRegistryDir, \%patch, 0x1);

  $rootdir = '/usr';

  my $redo = 1;
  while ($redo) {
    $answer = spacechk_answer('In which directory do you want '
                              . 'to install the binary files?', 'dirpath',
                              $rootdir . '/bin', './bin', 'BINDIR');
    undef %patch;
    $redo=install_dir('./bin', $answer, \%patch, 0x1, 1);
  }

  get_initscriptsdir();
  $initscriptsdir = db_get_answer('INITSCRIPTSDIR');

  #
  # Install the startup script (and make the old installer aware of this one)
  #
  undef %patch;
  install_file($cStartupFileName, $initscriptsdir . '/vmware', \%patch, 0x1);

  if (vmware_product() eq 'wgs') {
    # this is only relevant for wgs
    install_symlink($initscriptsdir . '/vmware',
                    $initscriptsdir . '/vmware-core');
    install_symlink($initscriptsdir . '/vmware',
                    $initscriptsdir . '/vmware-mgmt');
    install_symlink($initscriptsdir . '/vmware',
                    $initscriptsdir . '/vmware-autostart');
  }

  $gIsUninstallerInstalled = 1;

  # Setuid root
  safe_chmod(04555, $answer . '/vmware-ping');

  $rootdir = internal_dirname($answer);
  # Don't display a double slash (was bug 14109)
  if ($rootdir eq '/') {
    $rootdir = '';
  }

  # We don't use get_persistent_answer() here because once the user has
  # selected the root directory, we can give him better default answers than
  # his/her previous answers.  Even though this is asking for a directory,
  # the actual source of the files is within the source ./lib so the
  # spacechk_answer() below handles it.
  if (vmware_product() eq 'wgs' || vmware_product() eq 'ws') {
    $redo=1;
    while($redo) {
      $answer = get_answer('In which directory do you want to install '
                           . 'the daemon files?', 'dirpath', $rootdir . '/sbin');
      db_add_answer('SBINDIR', $answer);
      undef %patch;
      $redo=install_dir('./sbin', $answer, \%patch, 0x1, 1);
    }
    # Setuid root
    safe_chmod(04555, $answer . '/vmware-authd');
  }

  $redo=1;
  while ($redo) {
    $answer = spacechk_answer('In which directory do you want to install '
                              . 'the library files?', 'dirpath',
                              $rootdir . '/lib/vmware', './lib');
    db_add_answer('LIBDIR', $answer);
    $libdir = $answer;
    undef %patch;
    $redo=install_dir('./lib', $answer, \%patch, 0x1, 1);
  }
  # Setuid root
  safe_chmod(04555, $answer . '/bin/vmware-vmx');
  safe_chmod(04555, $answer . '/bin/vmware-vmx-debug');
  safe_chmod(04555, $answer . '/bin/vmware-vmx-stats');

  # If the product has man pages ask for the man pages location. */
  if (-d './man') {
    $mandir = $rootdir . '/share/man';
    if (not (-d $mandir)) {
      $mandir = $rootdir . '/man';
    }
    $answer = spacechk_answer('In which directory do you want to install '
                              . 'the manual files?', 'dirpath',
                              $mandir, './man');
    db_add_answer('MANDIR', $answer);
    undef %patch;
    install_dir('./man', $answer, \%patch, 0x1);
  }

  $docdir = $rootdir . '/share/doc';
  if (not (-d $docdir)) {
    $docdir = $rootdir . '/doc';
  }
  $answer = spacechk_answer('In which directory do you want to install '
                            . 'the documentation files?', 'dirpath',
                            $docdir . '/vmware', './doc');
  db_add_answer('DOCDIR', $answer);
  undef %patch;
  install_dir('./doc', $answer, \%patch, 0x1);
   install_symlink(db_get_answer('DOCDIR') . '/EULA',
                   $libdir . '/share/EULA.txt');

  # Don't forget the vix perl tar ball..
  if (-d 'vmware-vix/api' ) {
    undef %patch;
    # Create the parent directory separately so install_dir() can be called on the
    # specific subdir rather than any and all subdirs when passing just 'vmware-vix'.
    db_add_dir($libdir . '/vmware-vix');
    install_dir( './vmware-vix/api', $libdir . '/vmware-vix/api', \%patch, 0x1);
  }

  find_vix_tar();

  if (vmware_product() eq 'ws') {
    install_content_player();
  }

  if (vmware_product() eq 'ws') {
      configure_vnetlib();
  }
}

sub install_content_player {
  my %patch;
  install_dir('./system_etc', '/etc', \%patch, 1);
  undef %patch;
  install_dir('./usr', '/usr', \%patch, 1);
}

sub get_initscriptsdir {
  my $initdir;
  my $initscriptsdir;
  my $answer;

  if (vmware_product() eq 'tools-for-freebsd') {
    $initdir = '/usr/local/etc/rc.d';
    $initscriptsdir = '/usr/local/etc/rc.d';
    db_add_answer('INITDIR', $initdir);
    db_add_answer('INITSCRIPTSDIR', $initscriptsdir);
    return $initscriptsdir;
  }

  # The "SuSE version >= 7.1" way
  $initdir = '/etc/init.d';
  if (check_answer_initdirpath($initdir, 'default') eq '') {
    # The "SuSE version < 7.1" way
    $initdir = '/sbin/init.d';
    if (check_answer_initdirpath($initdir, 'default') eq '') {
      # The "RedHat" way
      $initdir = '/etc/rc.d';
      if (check_answer_initdirpath($initdir, 'default') eq '') {
        # The "Debian" way
        $initdir = '/etc';
        if (check_answer_initdirpath($initdir, 'default') eq '') {
          $initdir = '';
        }
      }
    }
  }
  $answer = get_persistent_answer('What is the directory that contains the init'
                                  .' directories (rc0.d/ to rc6.d/)?'
                                  , 'INITDIR', 'initdirpath', $initdir);

  # The usual way
  $initscriptsdir = $answer . '/init.d';
  if ( $answer =~ m/init.d/ ) {
    # if the string contains init.d, do not default to containing init.d,
    # instead just default to the initdir as the initscripstdir
    $initscriptsdir = $answer;
  }

  if (check_answer_initscriptsdirpath($initscriptsdir, 'default') eq '') {
    # The "SuSE version >= 7.1" way
    $initscriptsdir = $answer;
    if (check_answer_initscriptsdirpath($initscriptsdir, 'default') eq '') {
      $initscriptsdir = '';
    }
  }
  $answer = get_persistent_answer('What is the directory that contains the init'
                                  .' scripts?', 'INITSCRIPTSDIR'
                                  , 'initscriptsdirpath', $initscriptsdir);
  return $answer;
}

sub get_home_dir {
   return (getpwnam(get_user()))[7] || (getpwuid($<))[7];
}

sub get_user {
   if (defined $ENV{'SUDO_USER'}) {
      return $ENV{'SUDO_USER'};
   }
   else {
      return $ENV{'USER'};
   }
}

# Install a tar package or upgrade an already installed tar package
sub install_or_upgrade {
  if (vmware_product() eq 'acevm') {
     print wrap('Installing VMware ACE.  This may take from several minutes to over ' .
                'an hour depending upon its size.' . "\n\n", 0);
  } else {
     print wrap('Installing ' . vmware_product_name() . ".\n\n", 0);
  }

  if (vmware_product() eq 'api') {
    install_perl_api();
  } elsif (vmware_product() eq 'acevm') {
    if (acevm_is_instance_running()) {
     error ('Cannot install this package because this ACE appears to be ' .
	     'running. Please close the running ACE and run this setup ' .
	     'program again.' . "\n\n");
    }
    if ($gACEVMUpdate) {
      install_content_acevm_update();
    } else {
      install_content_acevm();
    }
    if (is_root()) {
      print wrap('You have installed this ACE package as the root user. This setup ' .
		 'package can change the ownership (chown) of the package files so ' .
		 'that another user may run this package.'. "\n\n", 0);
      my $user = get_answer('Enter a username to change package ownership',
			 'username', get_user());
      my ($name,$passwd,$uid,$gid,$quota,$comment,$gcos,$home) = getpwnam($user);

      if ($gACEVMUpdate) {
         system("chown -R $uid:$gid " . shell_string(db_get_answer('BINDIR')));
      } else {
         system("chown -R $uid:$gid " . shell_string($gFirstCreatedDir));
         system("chown -R $uid:$gid " . shell_string($home . '/.local'));
      }
    }
  } elsif (vmware_product() eq 'tools-for-linux' ||
           vmware_product() eq 'tools-for-freebsd' ||
           vmware_product() eq 'tools-for-solaris') {
    install_content_tools();
  } elsif (vmware_product() eq 'vix') {
    install_content_vix();
  } elsif (vmware_product() eq 'vix-disklib') {
      install_content_vix_disklib();
  } elsif (vmware_product() eq 'nvdk') {
      install_content_nvdk();
  } else {
    install_content();
    if (vmware_product() eq 'wgs') {
      install_content_webAccess();
    }
  }

  if (vmware_product() eq 'acevm' && (my $vmx = acevm_find_vmx($gRegistryDir)) ne '') {
    print wrap('The installation of this VMware ACE package completed successfully. '
	       . 'You can decide to remove this software from your system at any '
	       . 'time by invoking the following command: "'
	       . db_get_answer('BINDIR') . '/' . $gUninstallerFileName . '".'
	       . "\n\n", 0);

    print wrap('You can now run this ACE by invoking the following ' .
	       ' command: "vmplayer ' . $vmx . '"' . "\n\n", 0);
    print wrap('A shortcut to your ACE package has been added to your ' .
               'application menu under the "VMware ACE" folder.  You may have to ' .
               "logout and log back in for it to appear.\n\n", 0);
  } else {
    print wrap('The installation of ' . vmware_longname()
               . ' completed successfully. '
               . 'You can decide to remove this software from your system at any '
               . 'time by invoking the following command: "'
               . db_get_answer('BINDIR') . '/' . $gUninstallerFileName . '".'
               . "\n\n", 0);
  }

}

# Uninstall files and directories beginning with a given prefix
sub uninstall_prefix {
  my $prefix = shift;
  my $prefix_len;
  my $file;
  my $dir;

  $prefix_len = length($prefix);

  # Remove all files beginning with $prefix
  foreach $file (keys %gDBFile) {
    if (substr($file, 0, $prefix_len) eq $prefix) {
      uninstall_file($file);
    }
  }

  # Remove all directories beginning with $prefix
  # We sort them by decreasing order of their length, to ensure that we will
  # remove the inner ones before the outer ones
  foreach $dir (sort {length($b) <=> length($a)} keys %gDBDir) {
    if (substr($dir, 0, $prefix_len) eq $prefix) {
      uninstall_dir($dir, vmware_product() eq 'acevm' ? '1' : '0');
    }
  }
}

# Uninstall a tar package
sub uninstall {
  my $service_name = shift;
  my $hostVmplPresent = file_name_exist("$gHostVmplDir/host.vmpl");

  if ($hostVmplPresent && vmware_product() eq 'acevm') {
    if (!is_root()) {
      error ('This package installed host policies and must be uninstalled by a ' .
	     'system administrator. Try running this setup program with sudo ' .
	     'or contact your system administrator for help.' . "\n\n");
    } else {
      acevm_uninstall_host_policies();
      uninstall_file("$gHostVmplDir/ace.dat");
    }
  }

  # New school Upstart support for Linux Tools.
  if (vmware_product() eq 'tools-for-linux' and
      db_get_answer_if_exists('UPSTARTJOB')) {
    # XXX Consider using v_s_i_c below.
    print wrap('Stopping services for ' . vmware_product_name() . "\n\n", 0);
    vmware_service_issue_command($cServiceCommandSystem, 'stop');

  # Legacy SYSV/rc support for all products.
  } elsif (defined($gDBAnswer{'INITSCRIPTSDIR'})
      && db_file_in(db_get_answer('INITSCRIPTSDIR') . $service_name)) {

    if ((isDesktopProduct()) || (isServerProduct())) {
      # Check that there are no VMs active else the server will fail to stop.
      print wrap("Checking for active VMs:\n", 0);
      if (system(shell_string(db_get_answer('INITSCRIPTSDIR') . '/vmware') .
                    ' status vmcount > /dev/null 2>&1') >> 8 == 2) {
        my $msg = vmware_product_name() . ' cannot quiesce.  Please '
                                        . 'suspend or power off each VM.' . "\n\n";
        error($msg);
      }
      print wrap("There are no Active VMs.\n", 0);
    }

    # The installation process ran far enough to create the startup script
    my $status;
    # Stop the services
    print wrap('Stopping services for ' . vmware_product_name() . "\n\n", 0);
    $status = system(shell_string(db_get_answer('INITSCRIPTSDIR')
                                  . $service_name) . ' stop') >> 8;
    if ($status) {
      if ($status == 2) {
        # At least one instance of VMware is still running. We must refuse to
        # uninstall
        error('Unable to stop ' . vmware_product_name()
              . '\'s services. Aborting the uninstallation.' . "\n\n");
      }

      # Oh well, at worst the user will have to reboot the machine... The
      # uninstallation process should now go as far as possible
      print STDERR wrap('Unable to stop ' . vmware_product_name()
                        . '\'s services.' . "\n\n", 0);
    } else {
      print "\n";
    }

    my $init_style = db_get_answer_if_exists('INIT_STYLE');

    # In case service links were created the LSB way, remove them
    my $unlinked = 0;
    if ("$init_style" eq 'lsb') {
      if ($gHelper{'insserv'} ne '') {
        if (0 == system(shell_string($gHelper{'insserv'}) . ' -r '
                        . shell_string(db_get_answer('INITSCRIPTSDIR') . $service_name)
                                       . ' >/dev/null 2>&1')) {
          $unlinked = 1;
        }
        else {
          print wrap("WARNING: The installer initially used the " .
                     "insserv application to setup the vmware-tools service.  " .
                     "That application did not run successfully.  " .
                     "Please re-install the insserv application or check your settings.  " .
                     "This script will now attempt to manually remove the " .
                     "vmware-tools service.\n\n", 0);
        }
      }
    }

    # Use chkconfig
    if (($unlinked == 0) and ($gHelper{'chkconfig'} ne '')) {
       # We need to trim the leading '/' off of the service name.
       my $trim_service_name = (substr($service_name, 0, 1) eq '/')
               ? substr($service_name, 1) : $service_name;
       if (0 == system(shell_string($gHelper{'chkconfig'}) . ' --del ' . $trim_service_name)) {
          $unlinked = 1;
       }
       else {
         print wrap("WARNING: The installer initially used the " .
                    "chkconfig application to setup the vmware-tools service.  " .
                    "That application did not run successfully.  " .
                    "Please re-install the chkconfig application or check your settings.  " .
                    "This script will now attempt to manually remove the " .
                    "vmware-tools service.\n\n", 0);
       }
    }

    # Use update-rc.d
    if (($unlinked == 0) and ($gHelper{'update-rc.d'} ne '')) {
       # We need to trim the leading '/' off of the service name.
       my $trim_service_name = (substr($service_name, 0, 1) eq '/')
               ? substr($service_name, 1) : $service_name;
       if (0 == system(shell_string($gHelper{'update-rc.d'}) . ' -f ' . $trim_service_name .
	       ' remove')) {
          $unlinked = 1;
       }
       else {
         print wrap("WARNING: The installer initially used the " .
                    "update-rc.d application to setup the vmware-tools service.  " .
                    "That application did not run successfully.  " .
                    "Please re-install the update-rc.d application or check your settings.  " .
                    "This script will now attempt to manually remove the " .
                    "vmware-tools service.\n\n", 0);
       }
    }

    # If neither of the above worked, the links will be removed automatically
    # by the installer.
  }

  if (vmware_product() eq 'wgs') {
    uninstall_wgs();
  }

  # Check to see if this uninstall is part of an upgrade.  When an upgrade occurs,
  # an install ontop of a current product, the uninstall part is called with the
  # upgrade option set to 1.
  if (!defined($gOption{'upgrade'}) || $gOption{'upgrade'} == 0) {
    if (vmware_product() eq 'ws' || vmware_product() eq 'wgs') {
      uninstall_vix();
    }

    if (vmware_product() eq 'ws') {
      deconfigure_vnetlib();
    }
  }

  my $eclipse_dir = db_get_answer_if_exists('ECLIPSEDIR');
  if (defined $eclipse_dir) {
     system($gHelper{'rm'} . ' -rf ' . $eclipse_dir . '/../configuration/com.vmware.bfg*');
  }

  # Let the VMX know that we're uninstalling the Tools. We need to
  # do this before we remove the files, because we use guestd to
  # send the RPC. But we'd like to do it as late as possible in the
  # uninstall process so that we won't accidentally tell the VMX that the
  # Tools are gone when they're still there.
  if (!$open_vm_compat) {
    if (vmware_product() eq 'tools-for-linux' ||
        vmware_product() eq 'tools-for-freebsd' ||
        vmware_product() eq 'tools-for-solaris') {
      send_rpc('tools.set.version 0');
    }
  }
  uninstall_prefix('');
}

# Configure vnetlib
sub configure_vnetlib() {
    my $vnetlib = shell_string("$gDBAnswer{'BINDIR'}/vmware-networks");
    my $vers;
    my $ret;

    db_add_answer('NETWORKING', 'yes');

    # pre-vnetlib upgrade
    if (!db_get_answer_if_exists('VNETLIB_CONFED') && $gOption{'ws-upgrade'}) {
	print wrap("Migrating network settings... ", 0);
	if (system("$vnetlib --migrate-network-settings $gInstallerMainDB") == 0) {
	    db_add_answer('VNETLIB_CONFED', 'yes');
	    return 1;
	} else {
	    $vers = 0;
	}
    } elsif (db_get_answer_if_exists('VNETLIB_CONFED')) { # post-vnetlib upgrade
	$vers = 1;
    } else { # new install
	$vers = 0;
    }

    if ($vers == 0) {
	print wrap("Configuring default networks...\n\n", 0);
    } elsif ($vers == 1) {
	print wrap("Restoring network settings...\n\n", 0);
    }

    my $cmd = sprintf("%s --postinstall %s,%s,1 > /dev/null", $vnetlib, vmware_product(), $vers);
    $ret = system($cmd);

    if ($ret == 0) {
	db_add_answer('VNETLIB_CONFED', 'yes');
    }

    return $ret == 0;
}

# Cleanup after vnetlib
sub deconfigure_vnetlib() {
    foreach my $path ("$gRegistryDir/networking.*", "$gRegistryDir/vmnet*",
		      "/var/run/vmnat.*", "/var/log/vnetlib", "$gRegistryDir/networking",
		      "/var/run/vmnet-*") {
       system(shell_string($gHelper{'rm'}) . " -rf $path");
    }
}

#
# Given two strings where the format is a tuple of things separated by a '.'
# if more than one, i.e. X.Y, A.B.C, Z, determine which of the strings is
# of higher value representing a more recent version of a lib, say.
# This works 0.0.0b style lettered version strings.
#
# Result:
# If the Base String is greater than the New string, return 1.
# If the two are equal, return 0
# If the Base String is less than the New string, return -1.
sub compare_dot_version_strings {
   my ($base, $new) = @_;
   my @base_digits = split(/\./, $base);
   my @new_digits = split(/\./, $new);

   my $i = 0;

   # Use the smaller limit value so we dont go outside the bounds of the array.
   my $limit = $#base_digits > $#new_digits ? $#new_digits : $#base_digits;

   while (($i < $limit) && ($base_digits[$i] eq $new_digits[$i])) {
      $i++;
   }

   my $result;
   if (($i == $limit) && ($base_digits[$i] eq $new_digits[$i])) {
      if ($#base_digits == $#new_digits) {
         $result = 0;
      } elsif ($#base_digits < $#new_digits) {
         # if the new_digits string is longer, then it is greater.
         $result = -1;
      } else {
         # Else the base_digits is longer, and thus is greater
         $result = 1;
      }
   } else {
      if ($base_digits[$i] gt $new_digits[$i]) {
         $result = 1;
      } else {
         $result = -1;
      }
   }

   return $result;
}


sub install_content_vicli_perl {
   my %patch;
   my $shipped_ssl_version = '0.9.8';
   my $installed_ssl_version = '0';
   my $minimum_ssl_version = '0.9.7';
   my $ssleay_installed = 0;
   my $link_ssleay = 0;
   my $linker_installed = `which ld`;
   my $minimum_libxml_version = '2.6.26';
   my $installed_libxml_version = '0';

   my $OpenSSL_installed = 0;
   my $LibXML2_installed = 0;
   my $OpenSSL_dev_installed = 0;
   my $libxml_perl_installed = 1;

   my $e2fsprogs_installed = 0;
   my $e2fsprogs_version = '0';
   my $minimum_e2fsprogs_version = '1.38';

   my $vicliName = vmware_product_name();
   if ($] < 5.008) {
      error($vicliName . " requires Perl version 5.8 or later.\n\n");
   }

   unless(direct_command("perldoc -V 2> /dev/null")) {
      print wrap("warning: " . $vicliName . " requires Perldoc.\n Please install perldoc.\n\n");
   }

   # Determine version of libxml2 that's installed.
   foreach my $line (direct_command("ldconfig -v 2> /dev/null")) {
      chomp($line);
      # Only find lines related to libxml2
      if ($line !~ /->\s+libxml2\.so\.(\d+\.?\d*\.?\d*[a-zA-Z]*)/) {
         next;
      }

      if (compare_dot_version_strings($installed_libxml_version, $1) <= 0) {
         # report back the highest installed version of libxml2
         $installed_libxml_version = $1;
      }
   }

   if ( $installed_libxml_version eq '0' ) {
      print wrap("libxml2 is not installed on the system \n");
   } else {
      $LibXML2_installed = 1;
   }

   if (compare_dot_version_strings($installed_libxml_version, $minimum_libxml_version) < 0) {
       print wrap("libxml2 $minimum_libxml_version is required for " . $vicliName . ". \n" .
		   "Please install libxml2 $minimum_libxml_version or greater.\n\n");
   }

   # Determine greatest version of OpenSSL that's installed.
   # We need version 0.9.7 or greater.  We ship 0.9.8
   # Since we are root, lets use ldconfig to view the installed libraries
   foreach my $line (direct_command("ldconfig -v 2> /dev/null")) {
      chomp($line);
      # Only find lines related to libssl
      if ($line !~ /->\s+libssl\.so\.(\d+\.?\d*\.?\d*[a-zA-Z]*)/) {
         next;
      }
      if (compare_dot_version_strings($installed_ssl_version, $1) <= 0) {
         # report back the highest installed version of libssl
         $installed_ssl_version = $1;
      }
   }

   if ( $installed_ssl_version eq '0' ) {
      print wrap(" OpenSSL is not installed on the system \n");
   } else {
      $OpenSSL_installed = 1;
   }

   if (compare_dot_version_strings($installed_ssl_version, $minimum_ssl_version) < 0) {
	   print wrap("OpenSSL $minimum_ssl_version is required for encrypted connections.\n" .
                 "Please install OpenSSL and OpenSSL-devel version $minimum_ssl_version or greater.\n\n", 0);
   }

   # check for e2fsprogs-devel installed
   if ( direct_command("cat /etc/*-release | grep -i ubuntu") || direct_command("cat /proc/version | grep -i ubuntu") ) {
       my $libssl_dev = direct_command("dpkg-query -W -f='\${Version}\n' '*ssl-dev*' ");
       if ( $libssl_dev ) {
		   $OpenSSL_dev_installed = 1;
       }   else {
            print wrap("libssl-dev $minimum_ssl_version is required for encrypted connections.\n" .
                  "Please install libssl-dev version $minimum_ssl_version or greater.\n\n", 0);
       }

       my $e2fsprogs = direct_command("dpkg-query -W -f='\${Version}\n' e2fsprogs ");
       if ($e2fsprogs) {
          my @e2fs = split('-', $e2fsprogs);
          $e2fsprogs_version = $e2fs[0];
          $e2fsprogs_installed = 1;
       }

       if ( direct_command("dpkg-query -W -f'\${Status}\n' libxml-libxml-perl | grep not-installed ") ) {
           print wrap("libxml-libxml-perl package is not installed on the system. libxml-libxml-perl package must be installed for use by " . $vicliName . ":\n\n", 0);
           $libxml_perl_installed = 0;
       }

   } else {
      my @openssl_dev = direct_command("rpm -qa | grep 'ssl-dev'");

      foreach my $line (@openssl_dev)  {
         chomp($line);
         if ($line =~ /[a-zA-Z]*ssl-dev[a-zA-Z]*-(\d+\.?\d*\.?\d*[a-zA-Z]*)/) {
	    $OpenSSL_dev_installed = 1;
         }
      }

      if (! $OpenSSL_dev_installed) {
         print wrap("openssl $minimum_ssl_version is required for encrypted connections.\n" .
              "Please install openssl-devel version $minimum_ssl_version or greater.\n\n", 0);
      }

      my @e2fsprogs = split('\n', direct_command("rpm -qa | grep 'e2fsprogs'"));
      foreach my $line (@e2fsprogs)  {
         chomp($line);
         if ($line =~ /e2fsprogs-+([0-9\.]+)/) {
            $e2fsprogs_version = "$1";
            $e2fsprogs_installed = 1;
         }
      }
   }

   if (! $e2fsprogs_installed ) {
      print wrap("e2fsprogs is not installed on the system \n\n", 0);
   }

   if (compare_dot_version_strings($e2fsprogs_version, $minimum_e2fsprogs_version) < 0) {
       print wrap("e2fsprogs $minimum_e2fsprogs_version is required for UUID.\n" .
                 "Please install e2fsprogs $minimum_e2fsprogs_version or greater.\n\n", 0);
   }

   # Exit the insatllation if OpenSSL or LibXML or e2fsprogs not installed on system.
   if ( ! $OpenSSL_installed || ! $LibXML2_installed || ! $e2fsprogs_installed || ! $OpenSSL_dev_installed || ! $libxml_perl_installed ) {
      uninstall_file($gInstallerMainDB);
      exit 1;
   }

   # Make sure we are using a valid path for Crypt-SSLeay
   # Valid paths are
   # Crypt-SSLeay-0.55-0.9.7
   # Crypt-SSLeay-0.55-0.9.8
   # Use 0.9.8 for newer ssl libs
   my $SSLeay_ssl_version = '0.9.7';
   if (compare_dot_version_strings('0.9.8', $installed_ssl_version) <= 0) {
      # Then use 0.9.8
      $SSLeay_ssl_version = '0.9.8';
   }

   my @modules = (
     {'module' => 'Crypt::SSLeay',         'version' => '0.55',   'path' => "Crypt-SSLeay-0.55-$SSLeay_ssl_version"},
     {'module' => 'version',               'version' => '0.78',   'path' => 'version-0.78'},
     {'module' => 'IO::Compress::Base',    'version' => '2.005',  'path' => 'IO-Compress-Base-2.005'},
     {'module' => 'Compress::Zlib',        'version' => '2.005',  'path' => 'Compress-Zlib-2.005'},
     {'module' => 'IO::Compress::Zlib::Constants',    'version' => '2.005',  'path' => 'IO-Compress-Zlib-2.005'},
     {'module' => 'Compress::Raw::Zlib',   'version' => '2.017',  'path' => 'Compress-Raw-Zlib-2.017'},
     {'module' => 'Archive::Zip',          'version' => '1.20',   'path' => 'Archive-Zip-1.26'},
     {'module' => 'Data::Dumper',          'version' => '2.121',  'path' => 'Data-Dumper-2.121'},
     {'module' => 'Class::MethodMaker',    'version' => '2.10',   'path' => 'Class-MethodMaker-2.10'},
     {'module' => 'HTML::Parser',           'version' => '3.60',   'path' => 'HTML-Parser-3.60'},
     {'module' => 'UUID',                  'version' => '0.03',   'path' => 'UUID-0.03'},
     {'module' => 'Data::Dump',             'version' => '1.15',    'path' => 'Data-Dump-1.15'},
     {'module' => 'SOAP::Lite',             'version' => '0.710.08',  'path' => 'SOAP-Lite-0.710.08'},
     {'module' => 'URI',                   'version' => '1.37',   'path' => 'URI-1.37'},
     {'module' => 'XML::LibXML',           'version' => '1.63',   'path' => 'XML-LibXML-1.63'},
     {'module' => 'LWP',                   'version' => '5.805', 'path' => 'libwww-perl-5.805'},
     {'module' => 'XML::LibXML::Common',   'version' => '0.13',   'path' => 'XML-LibXML-Common-0.13'},
     {'module' => 'XML::NamespaceSupport', 'version' => '1.09',   'path' => 'XML-NamespaceSupport-1.09'},
     {'module' => 'XML::SAX',              'version' => '0.16',   'path' => 'XML-SAX-0.16'},
     {'module' => 'VMware::VIRuntime',     'version' => '0.9',    'path' => 'VMware'},
     {'module' => 'WSMan::StubOps',        'version' => '0.1',    'path' => 'WSMan'}
   );
   my @install; # list of modules to be installed

   my $lib_dir = $Config{'archlib'} || $ENV{'PERL5LIB'} || $ENV{'PERLLIB'} ||
      error("Unable to determine the Perl module directory.  You may set the " .
            "destination manually by setting the PERLLIB directory.\n\n");

   my $share_dir = $Config{'installprivlib'} || $ENV{'PERLSHARE'} ||
      error("Unable to determine share_dir.  You may set the destination " .
            "manually using PERLSHARE.\n\n");

   foreach my $module (@modules) {
      eval "require $module->{'module'}";
      if ($@) {
         push @install, $module;
      } elsif ($module->{'module'}->VERSION lt $module->{'version'}) {
         push @gLower, $module;
      }
   }

   # If SSLeay is going to be installed by us, they must have a linker on the system
   foreach my $module (@install) {
      if ($module->{'module'} eq 'Crypt::SSLeay') {
         if (! $linker_installed) {
            print wrap("No Crypt::SSLeay Perl module or linker could be found on the " .
                       "system.  Please either install SSLeay from your distribution " .
                       "or install a development toolchain and run this installer " .
                       "again for encrypted connections.\n\n", 0);
            uninstall();
            exit 1;
         } else {
            $link_ssleay = 1;
         }
      }
   }

   # install modules in @install
   foreach my $module (@install) {
      if ($module->{'module'} eq 'Crypt::SSLeay') {
         if ($link_ssleay) {
            my $path = "./lib/$module->{'path'}/lib/auto/Crypt/SSLeay";
            if ($] >= 5.010 && ( -e "./lib/5.10/$module->{'path'}/lib" ) )  {
               $path = "./lib/5.10/$module->{'path'}/lib/auto/Crypt/SSLeay";
            }

            if (system("ld -shared -o $path/SSLeay.so $path/SSLeay.o -lcrypto -lssl") >> 8) {
               print wrap("Unable to link the Crypt::SSLeay Perl module.  Secured " .
                          "connections will be unavailable until you install the " .
                          "Crypt::SSLeay module.\n\n", 0);
               uninstall();
               exit 1;
             }
         } else {
            next;
         }
      }

      undef %patch;
      if ($] >= 5.010 && ( -e "./lib/5.10/$module->{'path'}/lib" ) )  {
         install_dir("./lib/5.10/$module->{'path'}/lib", "$lib_dir", \%patch, 0x1);
      } elsif (-e "./lib/$module->{'path'}/lib") {
         install_dir("./lib/$module->{'path'}/lib", "$lib_dir", \%patch, 0x1);
      }

      undef %patch;
      if ($] >= 5.010 && ( -e "./lib/5.10/$module->{'path'}/share" ) )  {
         install_dir("./lib/5.10/$module->{'path'}/share", "$share_dir", \%patch, 0x1);
      } elsif (-e "./lib/$module->{'path'}/share") {
         install_dir("./lib/$module->{'path'}/share", "$share_dir", \%patch, 0x1);
      }
   }

   foreach my $module (@modules) {
        eval "require $module->{'module'}";
        if ($@) {
	   push @gMissing, $module;
        } else {
          next;
        }
   }
}

sub install_content_vix_disklib {
  my $rootdir;
  my $bindir;
  my $answer;
  my %patch;
  my $docdir;
  my $libdir;
  my $suffix = is64BitUserLand() ? '64' : '32';

  my $old_default = $gOption{'default'};
  $gOption{'default'} = 0;
  show_EULA();
  $gOption{'default'} = $old_default;

  undef %patch;

  install_dir('./etc', $gRegistryDir, \%patch, 0x1);

  $rootdir = get_persistent_answer("What prefix do you want to use to install " .
     vmware_product_name() . "?\n\n" . 'The prefix is the root directory where the other
     folders such as man, bin, doc, lib, etc. will be placed.', 'PREFIX', 'dirpath',
     '/usr');

  # Don't display a double slash (was bug 14109)
  if ($rootdir eq '/') {
    $rootdir = '';
  }

  undef %patch;
  $bindir = "$rootdir/lib/vmware-vix-disklib/bin";
  install_dir('./bin32', $bindir . '32', \%patch, 0x1);
  install_dir('./bin64', $bindir . '64', \%patch, 0x1);
  create_dir("$rootdir/bin", 1);
  install_symlink("$bindir$suffix/vmware-mount", "$rootdir/bin/vmware-mount");
  install_symlink("$bindir$suffix/vmware-vdiskmanager", "$rootdir/bin/vmware-vdiskmanager");
  install_symlink("$bindir$suffix/vmware-uninstall-vix-disklib.pl",
     "$rootdir/bin/vmware-uninstall-vix-disklib.pl");
  db_add_answer('BINDIR', "$rootdir/bin");

  $gIsUninstallerInstalled = 1;

  $libdir = "$rootdir/lib/vmware-vix-disklib/lib";
  undef %patch;
  install_dir('./lib32', $libdir . '32', \%patch, 0x1);
  install_dir('./lib64', $libdir . '64', \%patch, 0x1);

  foreach my $arch (qw(32 64)) {
     install_symlink("$libdir$arch/libssl.so.0.9.8", "$bindir$arch/libssl.so.0.9.8");
     install_symlink("$libdir$arch/libcrypto.so.0.9.8", "$bindir$arch/libcrypto.so.0.9.8");
  }
  db_add_answer('VIXDISKLIBDIR', $libdir);
  db_add_answer('LIBDIR', $libdir);

  undef %patch;
  install_dir('./include', "$rootdir/lib/vmware-vix-disklib/include", \%patch, 0x1);

  my $pkgdir = "$rootdir/lib/pkgconfig";
  create_dir($pkgdir, 1);
  foreach my $arch (qw(32 64)) {
     my $pcfile = "$pkgdir/vix-disklib-$arch.pc";
     if (open(PKGCONFIG, '>' . $pcfile)) {
       db_add_file($pcfile, 0);
       print PKGCONFIG "prefix=$rootdir/lib/vmware-vix-disklib\n";
       print PKGCONFIG "exec_prefix=\${prefix}\n";
       print PKGCONFIG "libdir=\${exec_prefix}/lib$arch\n";
       print PKGCONFIG "includedir=\${prefix}/include\n";
       print PKGCONFIG "Name: vix-disklib\n";
       print PKGCONFIG "Description: VMware VIX DiskLib\n";
       print PKGCONFIG "Version: " . vmware_version() . "\n";
       print PKGCONFIG "Libs: -L\${libdir} -lvixDiskLib\n";
       print PKGCONFIG "Cflags: -I\${includedir}\n";
       close PKGCONFIG;
     }
  }

  # Runtime
  install_symlink("vmware-vix-disklib/lib$suffix/libvixDiskLib.so.5",
                  "$rootdir/lib/libvixDiskLib.so.5");
  # Devel only
  install_symlink("vix-disklib-$suffix.pc", "$pkgdir/vix-disklib.pc");
  install_symlink("libvixDiskLib.so.5",
                  "$rootdir/lib/libvixDiskLib.so");

  $docdir = $rootdir . '/share/doc/vmware-vix-disklib';
  install_dir('./doc', $docdir, \%patch, 0x1);

  my @missing;
  my $ldd_out = direct_command(shell_string($gHelper{'ldd'}) . ' ' .
                "$rootdir/bin/vmware-mount");
  foreach my $lib (split(/\n/, $ldd_out)) {
    if ($lib =~ '(\S+) => not found') {
       push(@missing, $1);
    }
  }

  if (scalar(@missing) > 0) {
     print wrap("The following libraries could not be found on your system:\n", 0);
     print join("\n", @missing);
     print "\n\n";

     query('You will need to install these manually before you can run ' .
           vmware_product_name() . ".\n\nPress enter to continue.", '', 0);
  }

  return 1;
}

sub install_content_nvdk {
  my $rootdir;
  my $bindir;
  my $answer;
  my %patch;
  my $docdir;
  my $suffix = is64BitUserLand() ? '64' : '32';

  my $old_default = $gOption{'default'};
  $gOption{'default'} = 0;
  show_EULA();
  $gOption{'default'} = $old_default;

  undef %patch;

  install_dir('./etc', $gRegistryDir, \%patch, 0x1);

  $rootdir = get_persistent_answer("What prefix do you want to use to install " .
     vmware_product_name() . "?\n\n" . 'The prefix is the root directory where the other
     folders such as man, bin, doc, lib, etc. will be placed.', 'PREFIX', 'dirpath',
     '/usr');

  # Don't display a double slash
  if ($rootdir eq '/') {
    $rootdir = '';
  }

  undef %patch;
  $bindir = "$rootdir/lib/nvdk/bin";
  install_dir('./bin', $bindir, \%patch, 0x1);
  create_dir("$rootdir/bin", 1);
  install_symlink("$bindir/vmware-uninstall-nvdk.pl",
     "$rootdir/bin/vmware-uninstall-nvdk.pl");
  db_add_answer('BINDIR', "$rootdir/bin");

  $gIsUninstallerInstalled = 1;

  undef %patch;
  install_dir('./include', "$rootdir/lib/nvdk/include", \%patch, 0x1);

  my $pkgdir = "$rootdir/lib/pkgconfig";
  create_dir($pkgdir, 1);
  my $pcfile = "$pkgdir/nvdk.pc";
  if (open(PKGCONFIG, '>' . $pcfile)) {
     db_add_file($pcfile, 0);
     print PKGCONFIG "prefix=$rootdir/lib/nvdk\n";
     print PKGCONFIG "includedir=\${prefix}/include\n";
     print PKGCONFIG "Name: nvdk\n";
     print PKGCONFIG "Description: VMware NAS VAAI Development Kit\n";
     print PKGCONFIG "Version: " . vmware_version() . "\n";
     print PKGCONFIG "Cflags: -I\${includedir}\n";
     close PKGCONFIG;
  }

  $docdir = $rootdir . '/share/doc/nvdk';
  install_dir('./doc', $docdir, \%patch, 0x1);

  return 1;
}

# Ask the user for file locations for libs, bins, etc.  Check
# to see if this build is an official one or not, and show the
# EULA if it's not an official build.
sub install_content_vix {
  my $rootdir;
  my $answer;
  my %patch;
  my $mandir;
  my $docdir;
  my $initdir;
  my $initscriptsdir;
  my $libdir;

  undef %patch;
  install_dir('./etc', $gRegistryDir, \%patch, 0x1);

  if ('2248791' != 0) {
    # suspend any '--default' option to force user interaction here.  The user
    # must answer the EULA question before continuing.
    my $tmp = $gOption{'default'};
    $gOption{'default'} = 0;
    show_EULA();
    $gOption{'default'} = $tmp;
  }

  if (db_get_answer_if_exists('NESTED') &&
      db_get_answer('NESTED') eq 'yes' &&
      $gOption{'default'} == 1) {
      db_add_answer('TERSE', 'yes');
  }

  # If workstation is already installed and VIX has not already defined
  # it's own BINDIR, then base the default root on the workstation BINDIR.
  if (!defined(db_get_answer_if_exists('BINDIR'))) {
    my $newbin;
    if (-f $cInstallerMainDB) {
      $newbin = alt_db_get_answer($cInstallerMainDB, 'BINDIR');
      if (defined($newbin)) {
        db_add_answer('BINDIR', $newbin);
      }
    }
  }

  $rootdir = '/usr';
  $answer = $gOption{'prefix'} || spacechk_answer('In which directory do you want '
                                  . 'to install the ' . vmware_product_name()
                                  . ' binary files?', 'dirpath',
                                  $rootdir . '/bin', './bin', 'BINDIR');

  # Make sure stuff is installed in a 'bin' dir.
  my $basename = internal_basename($answer);
  if ($basename ne 'bin') {
    $answer = $answer . '/bin';
  }

  db_add_answer('BINDIR', $answer);
  undef %patch;
  install_dir('./bin', $answer, \%patch, 0x1);
  # We might be in a 'NESTED' install and workstation would have already
  # installed vmrun.  No reason to check for 'NESTED' really.  If we're
  # installed standalone, then the uninstall would remove vmrun.  If not,
  # then vmrun will already exist.
  if (! file_name_exist($answer . '/vmrun')) {
    my %patch;
    install_file('./vmware-vix/bin/vmrun', $answer . '/vmrun', \%patch, 0x1);
  }

  $rootdir = internal_dirname($answer);
  # Don't display a double slash (was bug 14109)
  if ($rootdir eq '/') {
    $rootdir = '';
  }
  $gIsUninstallerInstalled = 1;

  $libdir = 'vmware-vix/lib';
  $answer = spacechk_answer('In which directory do you want '
                            . 'to install the ' . vmware_product_name()
                            . ' library files?', 'dirpath',
                            $rootdir . '/lib/'. $libdir, 'vmware-vix/lib' );

  db_add_answer('VIXLIBDIR', $answer);
  db_add_answer('LIBDIR', $answer);

  undef %patch;
  install_dir($libdir, $answer, \%patch, 0x1);
  my $globallibdir = is64BitUserLand() ? '/lib64' : '/lib32';
  my $shared_object = 'libvixAllProducts.so';

  if ((! -d $globallibdir) && (! -d '/usr' . $globallibdir)) {
      install_symlink($answer . '/' . $shared_object, '/lib/' . $shared_object);
  } else {
    if (-d $globallibdir) {
      install_symlink($answer . '/' . $shared_object,
                    $globallibdir . '/' . $shared_object);
    }
    if (-d '/usr' . $globallibdir) {
      install_symlink($answer . '/' . $shared_object,
                      '/usr' . $globallibdir . '/' . $shared_object);
    }
  }

  # If the product has man pages ask for the man pages location. */
  if (-d './man') {
    $mandir = $rootdir . '/share/man';
    if (not (-d $mandir)) {
      $mandir = $rootdir . '/man';
    }
    $answer = spacechk_answer('In which directory do you want '
                              . 'to install the ' . vmware_product_name()
                              . ' man pages?', 'dirpath',
                              $rootdir . '/man', 'vmware-vix/man');
    db_add_answer('MANDIR', $answer);
    undef %patch;
    install_dir('vmware-vix/man', $answer, \%patch, 0x1);
  }

  $docdir = $rootdir . '/share/doc';
  if (not (-d $docdir)) {
    $docdir = $rootdir . '/doc';
  }
  $answer = spacechk_answer('In which directory do you want '
                            . 'to install the ' . vmware_product_name()
                            . ' document pages?', 'dirpath',
                            $docdir . '/vmware-vix', 'doc');

  undef %patch;
  install_dir('./doc', $answer, \%patch, 0x1);
  db_add_answer('DOCDIR', $answer);
  undef %patch;
  install_dir('vmware-vix/include', $rootdir . '/include', \%patch, 0x1);
  undef %patch;
  install_dir('vmware-vix/api', db_get_answer('VIXLIBDIR') . '/api', \%patch, 0x1);

  # tell the Vix world where to find the libs, putting the VIXLIBDIR value
  # into /etc/vmware/config.
  finalize_vix_install();

  # Make sure the verbose meter is turned up.
  db_remove_answer('TERSE');

  return 1;
}

# Add the variable, vix.libdir, to /etc/vmware/config
# so the Vix API can figure out where its libraries
# are.  If this is the standalone version, create config.
sub finalize_vix_install {
  if (! -d "/etc/vmware") {
    create_dir("/etc/vmware", 0x1);
  }

  my $libdir = db_get_answer_if_exists('VIXLIBDIR');

  if (!defined($libdir)) {
      error("Unable to look up VIX libdir.\n");
  }

  $gConfig->set("vix.libdir", $libdir);

  if (!$gConfig->writeout($gConfigFile)) {
      error("Unable to write VIX libdir to configuration file.\n");
  }
}

# find the vix tar package within the workstation distribution tree and install
# it into db_get_answer('LIBDIR')/vmware-vix
sub find_vix_tar {
  my %patch;
  my $vixTarFile = 'vmware-vix/vmware-vix.tar.gz';
  my $vixInstalledTarFile = db_get_answer('LIBDIR') . '/' . $vixTarFile;

  # If this is a workstation tar install there will be a vix tarball:
  # vmware-distrib/vmware-vix/vmware-vix.tar.gz.  "Install" it into
  # its final spot in the tree.  If this is an rpm install, the tarball
  # will already be in its final location.  This is where the vmware-config
  # script will look for the tar file.
  if (-e $vixTarFile) {
    undef %patch;
    install_file($vixTarFile, $vixInstalledTarFile, \%patch, 0x1);
    return 1;
  }
  return 0;
}

# Remove the text we added to the core config file in
# /etc/vmware/config.  Call uninstall on the whole tree.
sub uninstall_vix {
  my @statbuf;

  # If this is not the Vix product in here, then the only thing to do is to launch
  # the Vix uninstaller.  When Vix comes through here, skipping this if, all of
  # the normal uninstall pieces occurr.
  if (vmware_product() ne 'vix') {
    my $where = alt_db_get_answer('/etc/vmware-vix/locations', 'BINDIR');
    if ($where) {
      $where .= '/vmware-uninstall-vix.pl';
      if (-f $where) {
        system(shell_string($where));
      }
    }
    return;
  }

  $gConfig->remove('vix.libdir');
  if (!$gConfig->writeout($gConfigFile)) {
      error("Unable to write VIX libdir to configuration file.\n");
  }

  # If we just removed the last bits from the file, statbuf[7] == size in bytes,
  # then remove the file so it won't get left behind in an uninstall.
  @statbuf = stat($gConfigFile);
  if ( !$statbuf[7]) {
    unlink ($gConfigFile);
  }

  uninstall_prefix('');

  # check to see if $gRegistryDir is still around.  If it has no files,
  # remove it.
  if (-d $gRegistryDir) {
    if (!direct_command('find ' .  $gRegistryDir . '  -type f -o -type l')) {
      rmdir($gRegistryDir);
    }
  }

}

# Return the specific VMware product
sub vmware_product {
  return 'vix-disklib';
}

# this is a function instead of a macro in the off chance that product_name
# will one day contain a language-specific escape character.
sub vmware_product_name {
  return 'VMware VIX DiskLib API';
}

# This function returns i386 under most circumstances, returning x86_64 when
# the product is Workstation and is the 64bit version at that.
sub vmware_product_architecture {
  return 'x86_64';
}

# Return product name and version
sub vmware_longname {
   my $name = vmware_product_name() . ' ' . vmware_version();

   if (not (vmware_product() eq 'server')) {
      if (vmware_product() eq 'tools-for-solaris') {
        $name .= ' for Solaris';
      } elsif (vmware_product() eq 'tools-for-freebsd') {
        $name .= ' for FreeBSD';
      } else {
        $name .= ' for Linux';
      }
   }

   return $name;
}

# If this was a WGS build, remove our inetd.conf entry for auth daemon
# and stop the vmware-serverd
sub uninstall_wgs {

  system(shell_string($gHelper{'killall'}) . ' -TERM vmware-serverd  >/dev/null 2>&1');
  uninstall_superserver();
}

sub install_content_webAccess {
  my %patch;

  undef %patch;
  install_dir("./webAccess", db_get_answer('LIBDIR') . "/webAccess", \%patch, 0x1);
}

# Try and figure out which "superserver" is installed and unconfigure correct
# one.
sub uninstall_superserver {
  my $inetd_conf  = "/etc/inetd.conf";
  my $xinetd_dir  = "/etc/xinetd.d";

  # check for xinetd
  # XXX Could be a problem, as they could start xinetd with '-f config_file'.
  #     We could do a ps -ax, look for xinetd, parse the line, find the config
  #     file, parse the config file to find the xinet.d directory.  Or parse if
  #     from the init.d script somewhere.  If they use init.d.
  if ( -d $xinetd_dir ) {
    uninstall_xinetd($xinetd_dir);
  }

  # check for inetd
  if ( -e $inetd_conf ) {
    uninstall_inetd($inetd_conf);
  }
}

# Restart the inetd service
sub restart_inetd {
  my $inetd_restart = db_get_answer('INITSCRIPTSDIR') . '/inetd';
  if (-e $inetd_restart) {
    if (!system(shell_string($inetd_restart) . ' restart')) {
      return;
    }
  }

  if (check_is_running('inetd')) {
    system(shell_string($gHelper{'killall'}) . ' -HUP inetd');
  }
}

# Cleanup the inetd.conf file.
sub uninstall_inetd {
  my $inetd = shift;
  my %patch = ('^# VMware auth.*$' => '',
          '^.*stream\s+tcp\s+nowait.*vmauthd.*$' => '',
          '^.*stream\s+tcp\s+nowait.*vmware-authd.*$' => '');
  my $tmp_dir = make_tmp_dir('vmware-installer');
  # Build the temp file's path
  my $tmp = $tmp_dir . '/tmp';

  # XXX Use the block_*() API instead, like we do for $cServices.
  internal_sed($inetd, $tmp, 0, \%patch);
  undef %patch;

  if (not internal_sed($tmp, $inetd, 0, \%patch)) {
    print STDERR wrap('Unable to copy file ' . $tmp . ' back to ' . $inetd
                      . '.' . "\n" . 'The authentication daemon was not removed from '
                      . $inetd . "\n\n", 0);
  }
  remove_tmp_dir($tmp_dir);
  restart_inetd();
}

#Restart xinetd
sub restart_xinetd {
  my $xinetd_restart = db_get_answer('INITSCRIPTSDIR') . '/xinetd';
  if (-e $xinetd_restart) {
    if (!system(shell_string($xinetd_restart) . ' restart')) {
      return;
    }
  }

  if (check_is_running('xinetd')) {
    system(shell_string($gHelper{'killall'}) . ' -USR2 xinetd');
  }
}


# Cleanup the xinetd.d directory.
sub uninstall_xinetd {
  my $conf_dir = shift;
  my $tmp_dir;
  my $tmp;

  # Unregister the IP service.
  $tmp_dir = make_tmp_dir('vmware-installer');
  $tmp = $tmp_dir . '/tmp';
  if (block_remove($cServices, $tmp, $cMarkerBegin, $cMarkerEnd) >= 0) {
    system(shell_string($gHelper{'mv'}) . ' -f ' . shell_string($tmp) . ' '
           . shell_string($cServices));
  }
  remove_tmp_dir($tmp_dir);

  restart_xinetd();
}


# Display a usage error message for the install program and exit
sub install_usage {
  print STDERR wrap(vmware_longname() . ' installer' . "\n" . 'Usage: ' . $0
                    . ' [[-][-]d[efault]]' . "\n"
                    . '    default: Automatically answer questions with the '
                    . 'proposed answer.'
		    . "\n"
                    . ' [[-][-]prefix=<path to install product: bin, lib, doc>]'
                    . '    Put the installation at <path> instead of the default '
                    . "location.  This implies '--default'."
		    . "\n"
		    . '--clobber-kernel-modules=<module1,module2,...>'
		    . '    Forcefully removes any VMware related modules '
		    . 'installed by any other installer and installs the modules provided '
		    . 'by this installer.  This is a comma seperated list of modules.'
		    . "\n\n", 0);
  exit 1;
}

# Remove a temporary directory
sub remove_tmp_dir {
  my $dir = shift;

  if (system(shell_string($gHelper{'rm'}) . ' -rf ' . shell_string($dir))) {
    error('Unable to remove the temporary directory ' . $dir . '.' . "\n\n");
  };
}

# ARGH! More code duplication from pkg_mgr.pl
# We really need to have some kind of include system
sub get_cc {
  $gHelper{'gcc'} = '';
  if (defined($ENV{'CC'}) && (not ($ENV{'CC'} eq ''))) {
    $gHelper{'gcc'} = internal_which($ENV{'CC'});
    if ($gHelper{'gcc'} eq '') {
      print wrap('Unable to find the compiler specified in the CC environnment variable: "'
                 . $ENV{'CC'} . '".' . "\n\n", 0);
    }
  }
  if ($gHelper{'gcc'} eq '') {
    $gHelper{'gcc'} = internal_which('gcc');
    if ($gHelper{'gcc'} eq '') {
      $gHelper{'gcc'} = internal_which('egcs');
      if ($gHelper{'gcc'} eq '') {
        $gHelper{'gcc'} = internal_which('kgcc');
        if ($gHelper{'gcc'} eq '') {
          $gHelper{'gcc'} = DoesBinaryExist_Prompt('gcc');
        }
      }
    }
  }
  print wrap('Using compiler "' . $gHelper{'gcc'}
             . '". Use environment variable CC to override.' . "\n\n", 0);
  return $gHelper{'gcc'};
}

# These quaddot functions and compute_subnet are from config.pl and are needed
# for the tar4|rpm4 upgrade
# Converts an quad-dotted IPv4 address into a integer
sub quaddot_to_int {
  my $quaddot = shift;
  my @quaddot_a;
  my $int;
  my $i;

  @quaddot_a = split(/\./, $quaddot);
  $int = 0;
  for ($i = 0; $i < 4; $i++) {
    $int <<= 8;
    $int |= $quaddot_a[$i];
  }

  return $int;
}

# Converts an integer into a quad-dotted IPv4 address
sub int_to_quaddot {
  my $int = shift;
  my @quaddot_a;
  my $i;

  for ($i = 3; $i >= 0; $i--) {
    $quaddot_a[$i] = $int & 0xFF;
    $int >>= 8;
  }

  return join('.', @quaddot_a);
}

# Compute the subnet address associated to a couple IP/netmask
sub compute_subnet {
  my $ip = shift;
  my $netmask = shift;

  return int_to_quaddot(quaddot_to_int($ip) & quaddot_to_int($netmask));
}

#
# Check to see if a conflicting product is installed and how it relates
# to the new product being installed, asking the user relevant questions.
# Based on user feedback, the conflicting product will either be removed,
# or the installation will be aborted.
#
sub prompt_and_uninstall_conflicting_products {

}

#
# This sub fetches the installed product's binfile and returns it.
# It returns '' if there is no product, 'UNKNOWN' if a product but
# no known bin.
#
sub get_installed_product_bin {
  my $binfile;

  # If there's no database, then there isn't any
  # previously installed product.
  my $tmp_db = $gInstallerMainDB;

  if ((not isDesktopProduct()) && (not isServerProduct())) {
    return 'UNKNOWN';
  }

  # If the installer DB is missing there is no product already installed so
  # there is no mismatch.
  # If not_configured is found, then install has already run once and has
  # uninstalled everything.
  if (not -e $gInstallerMainDB || -e $gRegistryDir . '/' . $gConfFlag) {
    return '';
  }

  db_load();
  my $bindir = db_get_answer('BINDIR');
  if (-f $bindir . "/vmware") {
    $binfile = $bindir . "/vmware";
  } elsif (-f $bindir . "/vmplayer") {
    $binfile = $bindir . "/vmplayer";
  } else {
    # There is no way to tell what may currently be installed, but something
    # is still around if the database is found.
    return 'UNKNOWN';
  }
  return $binfile;
}

#
# Check to see if the product we are installing is the same as the
# currently installed product, this is used to tell whether we are in
# what would be considered an upgrade situation or a conflict.
#
# return = 0:  There is a match
#        = 1:  There is a mismatch
#
sub installed_product_mismatch {
  my $msg;
  my $binfile = get_installed_product_bin();
  if ( $binfile eq '' ){
    return 0;
  }
  if ( $binfile eq 'UNKNOWN' ){
    return 1;
  }
  my $product_str = direct_command($binfile . ' -v');
  my $product_name = vmware_product_name();
  if ($product_str =~ /$product_name/){
    return 0;
  }

  return 1;
}

#
# Given a product version string ala 'VMware Server X.X.X build-000000', break
# down the Xs and return a value that shows which string represents a newer
# version number, the same version number, or an older version number.  X may be
# a digit or a letter, as in e.x.p build-000000
#
sub compare_version_strings {
   my $version_str_A = shift;
   my $version_str_B = shift;
   my $index = 0;

   # Match on non-spaces to allow for either numbers or letters.  I.E. e.x.p and 1.0.4
   $version_str_A =~ s/\D*(\S+.\S+.\S+)\s+build-(\d+)/$1.$2/;
   $version_str_B =~ s/\D*(\S+.\S+.\S+)\s+build-(\d+)/$1.$2/;

   chomp($version_str_A);
   chomp($version_str_B);
   my @versions_A = split(/\./, $version_str_A);
   my @versions_B = split(/\./, $version_str_B);

   while (($index < $#versions_A + 1) && ($versions_A[$index] eq $versions_B[$index])) {
      $index++;
   }
   if ($index > $#versions_A) {
      $index = $#versions_A;
   }

   my $result;
   if ($versions_A[$index] =~ /\d+/ && $versions_B[$index] =~ /\d+/) {
      $result = $versions_A[$index] - $versions_B[$index];
   } elsif ($versions_A[$index] =~ /\w+/ && $versions_B[$index] =~ /\d+/) {
      $result = -1;
   } elsif ($versions_A[$index] =~ /\d+/ && $versions_B[$index] =~ /\w+/) {
      $result =  1;
   } else {
      $result =  0;
   }

   return $result;
}

#
# Check to see what product is installed, and how it relates to the
# new product being installed, asking the user relevant questions,
# and allowing the user to abort(error out) if they don't want the
# existing installed product to be removed (as in for an up/downgrade
# or conflicting product).
#
sub prompt_user_to_remove_installed_product {
  # First off, only a few products even have "mismatches", i.e. can possibly conflict.
  if (((vmware_product() eq 'wgs') ||
       (vmware_product() eq 'ws') ||
       (vmware_product() eq 'player')) &&
      (installed_product_mismatch() != 0)) {
    if (get_answer('You have a product that conflicts with '.vmware_product_name().' installed.  ' .
                   'Continuing this install will first uninstall this product.  ' .
                   'Do you wish to continue? (yes/no)', 'yesno', 'yes') eq 'no') {
      error "User canceled install.\n";
    }
    return;
  }
  #Now that the group of other-conflicting products is handled, we are sure this product simply
  #conflicts with itself, even if its one of those.
  my $binfile = get_installed_product_bin();
  if ( $binfile eq 'UNKNOWN' or $binfile eq '' ){
    #Without a binfile, we can't detect version, so we simply warn the user we are about to uninstall
    #and ask them if they want that.
    if (get_answer('You have a version of '.vmware_product_name().' installed.  ' .
                   'Continuing this install will first uninstall the currently installed version.' .
                   '  Do you wish to continue? (yes/no)', 'yesno', 'yes') eq 'no') {
      error "User canceled install.\n";
    }
    return;
  }

  my $product_str = direct_command($binfile . ' -v');
  my $installed_version = direct_command($binfile . ' -v');
  my $product_version = vmware_version();
  if (compare_version_strings($installed_version, $product_version) > 0) {
    if (get_answer('You have a more recent version of '.vmware_product_name().' installed.  ' .
                   'Continuing this install will DOWNGRADE to the latest version by first ' .
                   'uninstalling the more recent version.  Do you wish to continue? (yes/no)', 'yesno', 'no') eq 'no') {
      error "User canceled install.\n";
    }
  } else {
    if (get_answer('You have a previous version of '.vmware_product_name().' installed.  ' .
                   'Continuing this install will upgrade to the latest version by first ' .
                   'uninstalling the previous version.  Do you wish to continue? (yes/no)', 'yesno', 'yes') eq 'no') {
      error "User canceled install.\n";
    }
  }
}

#
# preuninstall_installed_tools
#
# hook scripts to run before uninstalling previously installed tools

sub preuninstall_installed_tools {
  # esx35* tools will backup system configuration file during installation
  # and restore the backuped file when to reconfigure tools or uninstall tools.
  # It is flawed in that user's modification made between backup and restore·
  # will lost. Specificly /etc/fstab was affected and reported as PR 400907.
  #
  # Below is a fix to keep user's modification by preventing uninstaller from·
  # restore /etc/fstab. But it does not fix other configuration lost problem.
  my $version;
  my $file;
  my $answer;
  my %files_to_keep;
  my @files_to_restore;
  my @files_to_restore_filtered;

  %files_to_keep = (
    "OLD_FSTAB" => undef,
  );    #can be extended to other backups

  if (-e $gInstallerMainDB && -x $gInstallerObject) {
    # check installer database version
    if (system(shell_string($gInstallerObject) . ' version >/dev/null 2>&1')) {
      $version = '1';
    } else {
      $version = direct_command(shell_string($gInstallerObject) . ' version');
      chop($version);
    }

    #esx35* and above are of version 4.
    if ($version == 4) {
      db_load();  #initialize gDBAnswer
      open(INSTALLDB, '>>' . $gInstallerMainDB);

      #filter the RESTORE_BACK_LIST, remove files that we want to keep
      $answer = db_get_answer_if_exists("RESTORE_BACK_LIST");
      if (defined($answer)) {
	@files_to_restore = split(':', $answer);
	@files_to_restore_filtered = ();
	foreach $file (@files_to_restore) {
	  if (!exists($files_to_keep{$file})) {
	    push(@files_to_restore_filtered, $file);
	  }
	}

	#save back to db
	if (@files_to_restore > @files_to_restore_filtered) {
	  $answer = join(":", @files_to_restore_filtered);
	  db_remove_answer("RESTORE_BACK_LIST");
	  db_add_answer("RESTORE_BACK_LIST", $answer);
	}
      }

      # Add INITRDMODS_CONF_VALS, so that it won't fail the old uninstaller.
      # And this is PR 983072.
      $answer = db_get_answer_if_exists("INITRDMODS_CONF_VALS");
      if (!defined($answer)) {
         db_add_answer("INITRDMODS_CONF_VALS", "");
      }

      db_save();  #close db
    }
  }
}

#
# remove_outdated_products
#
# Based on the gOldUninstallers list, prompt the user to remove these
# installations of these programs if they exist.  Otherwise bail out
# if the user does not want to uninstall them.
#
# SIDE EFFECTS:
#    Will invoke old installers if found and may cause the install
#    to fail if the old installer fails.
#

sub remove_outdated_products {
  my $oldUninstaller;
  my $status;
  foreach $oldUninstaller (@gOldUninstallers) {
     if ( -x $oldUninstaller ) {
        # Then we have found an old named version of this program, and should
        # uninstall it.  We also have to nuke the database because it will
        # contain incorrect information regarding older path names. -astiegmann
        my $msg = 'An Older version of ' . vmware_product_name() . ' with a '
                . 'different name was found on your system.  Would you like '
                . 'to uninstall it?';
        if (get_answer($msg, 'yesno', 'yes') eq 'no') {
           error("User cancelled install.\n");
        }
        print wrap('Running ' . $oldUninstaller . "...\n",0);
        $status = system(shell_string($oldUninstaller) . ' uninstall');
        if ($status) {
           error("Uninstall of the old program has failed. "
               . " Please correct the failure and re run the install.\n\n");
        }
     }
  }
}

#
# Make sure we have an initial database suitable for this installer. The goal
# is to encapsulates all the compatibilty issues in this (consequently ugly)
# function
#
# SIDE EFFECTS:
#      This function uninstalls previous products found (now managed by
#      prompt_user_to_remove_installed_product)
#

sub get_initial_database {
  my $made_dir1;
  my $made_dir2;
  my $bkp_dir;
  my $bkp;
  my $kind;
  my $version;
  my $intermediate_format;
  my $status;
  my $state_file;
  my $state_files;
  my $clear_db = 0;

  # Check for older products with a different name, and uninstall them if
  # we can find their uninstall programs.
  remove_outdated_products();

  if (not (-e $gInstallerMainDB)) {
    create_initial_database();
    return;
  }

  print wrap('A previous installation of ' . vmware_product_name()
             . ' has been detected.' . "\n\n", 0);

  #
  # Convert the previous installer database to our format and backup it
  # Uninstall the previous installation
  #

  $bkp_dir = make_tmp_dir('vmware-installer');
  $bkp = $bkp_dir . '/prev_db.tar.gz';

  if (-x $gInstallerObject) {
    $kind = direct_command(shell_string($gInstallerObject) . ' kind');
    chop($kind);
    if (system(shell_string($gInstallerObject) . ' version >/dev/null 2>&1')) {
      # No version method -> this is version 1
      $version = '1';
    } else {
      $version = direct_command(shell_string($gInstallerObject) . ' version');
      chop($version);
    }
    print wrap('The previous installation was made by the ' . $kind
               . ' installer (version ' . $version . ').' . "\n\n", 0);

    if ($version < 2) {
      # The best database format those installers know is tar. We will have to
      # upgrade the format
      $intermediate_format = 'tar';
    } elsif ($version == 2) {
      # Those installers at least know about the tar2 database format. We won't
      # have to do too much
      $intermediate_format='tar2'
    } elsif ($version == 3) {
      # Those installers at least know about the tar3 database format. We won't
      # have to do much
      $intermediate_format = 'tar3';
    } else {
      # Those installers at least know about the tar4 database format. We won't
      # have to do anything
      $intermediate_format = 'tar4';
    }
    system(shell_string($gInstallerObject) . ' convertdb '
           . shell_string($intermediate_format) . ' ' . shell_string($bkp));

    # Uninstall the previous installation
    if (((vmware_product() eq 'wgs') ||
        (vmware_product() eq 'ws') ||
        (vmware_product() eq 'player')) &&
        (installed_product_mismatch() != 0)) {
        $clear_db = 1;
    }
    # Remove any installed product *if* user accepts.
    prompt_user_to_remove_installed_product();
    if (isToolsProduct()) {
      preuninstall_installed_tools();
    }
    $status = system(shell_string($gInstallerObject) . ' uninstall --upgrade');
    if ($status) {
      error("Uninstall failed.  Please correct the failure and re run the install.\n\n");
    }
    if (vmware_product() eq 'ws') {
	$gOption{'ws-upgrade'} = 1;
    }

    # Beware, beyond this point, $gInstallerObject does not exist
    # anymore.
  } else {
    # No installer object -> this is the old installer, which we don't support
    # anymore.
    $status = 1;
  }
  if ($status) {
    remove_tmp_dir($bkp_dir);
    # remove the installer db so the next invocation of install can proceed.
    if (get_answer('Uninstallation of previous install failed. ' .
		   'Would you like to remove the install DB?', 'yesno', 'no') eq 'yes') {
      print wrap('Removing installer DB, please re-run the installer.' . "\n\n", 0);
      unlink $gInstallerMainDB;
    }

    error('Failure' . "\n\n");
  }

  if ($clear_db == 1) {
    create_initial_database();
    return;
  }

  # Create the directory structure to welcome the restored database
  $made_dir1 = 0;
  if (not (-d $gRegistryDir)) {
    safe_mkdir($gRegistryDir);
    $made_dir1 = 1;
  }
  safe_chmod(0755, $gRegistryDir);
  $made_dir2 = 0;
  if ($version >= 2) {
    if (not (-d $gStateDir)) {
      safe_mkdir($gStateDir);
      $made_dir2 = 1;
    }
    safe_chmod(0755, $gStateDir);
  }

  # Some versions of tar (1.13.17+ are ok) do not untar directory permissions
  # as described in their documentation (they overwrite permissions of
  # existing, non-empty directories with permissions stored in the archive)
  #
  # Because we didn't know about that at the beginning, the previous
  # uninstallation may have included the directory structure in their database
  # backup.
  #
  # To avoid that, we must re-package the database backup
  if (vmware_product() eq 'tools-for-solaris') {
    # Solaris' default tar(1) does not support gnu tar's -C or -z options.
    system('cd ' . shell_string($bkp_dir) . ';'
           . shell_string($gHelper{'gunzip'}) . ' -c ' . shell_string($bkp)
           . ' | ' . shell_string($gHelper{'tar'}) . ' -xopf -');
  } else {
    system(shell_string($gHelper{'tar'}) . ' -C ' . shell_string($bkp_dir)
           . ' -xzopf ' . shell_string($bkp));
  }
  $state_files = '';
  if (-d $bkp_dir . $gStateDir) {
    foreach $state_file (internal_ls($bkp_dir . $gStateDir)) {
      $state_files .= ' ' . shell_string('.' . $gStateDir . '/'. $state_file);
    }
  }
  $bkp = $bkp_dir . '/prev_db2.tar.gz';
  if (vmware_product() eq 'tools-for-solaris') {
    system('cd ' . shell_string($bkp_dir) . ';'
           . shell_string($gHelper{'tar'}) . ' -copf - '
           . shell_string('.' . $gInstallerMainDB) . $state_files
           . ' | ' . shell_string($gHelper{'gzip'}) . ' > ' . shell_string($bkp));
  } else {
    system(shell_string($gHelper{'tar'}) . ' -C ' . shell_string($bkp_dir)
           . ' -czopf ' . shell_string($bkp) . ' '
           . shell_string('.' . $gInstallerMainDB) . $state_files);
  }

  # Restore the database ready to be used by our installer
  if (vmware_product() eq 'tools-for-solaris') {
    system('cd /;'
           . shell_string($gHelper{'gunzip'}) . ' -c ' . shell_string($bkp)
           . ' | ' . shell_string($gHelper{'tar'}) . ' -xopf -');
  } else {
    system(shell_string($gHelper{'tar'}) . ' -C / -xzopf ' . shell_string($bkp));
  }
  remove_tmp_dir($bkp_dir);

  if ($version < 2) {
    print wrap('Converting the ' . $intermediate_format
               . ' installer database format to the tar4 installer database format.'
               . "\n\n", 0);
    # Upgrade the database format: keep only the 'answer' statements, and add a
    # 'file' statement for the main database file
    my $id;

    db_load();
    if (not open(INSTALLDB, '>' . $gInstallerMainDB)) {
      error('Unable to open the tar installer database ' . $gInstallerMainDB
            . ' in write-mode.' . "\n\n");
    }
    db_add_file($gInstallerMainDB, 0);
    foreach $id (keys %gDBAnswer) {
      print INSTALLDB 'answer ' . $id . ' ' . $gDBAnswer{$id} . "\n";
    }
    db_save();
  } elsif( $version == 2 ) {
    print wrap('Converting the ' . $intermediate_format
               . ' installer database format to the tar4 installer database format.'
               . "\n\n", 0);
    # Upgrade the database format: keep only the 'answer' statements, and add a
    # 'file' statement for the main database file
    my $id;

    db_load();
    if (not open(INSTALLDB, '>' . $gInstallerMainDB)) {
      error('Unable to open the tar installer database ' . $gInstallerMainDB
            . ' in write-mode.' . "\n\n");
    }
    db_add_file($gInstallerMainDB, 0);
    foreach $id (keys %gDBAnswer) {
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
      # removed (and not converted):
      #   VNET_SAMBA             -> VNET_1_SAMBA
      #   VNET_SAMBA_MACHINESID  -> VNET_1_SAMBA_MACHINESID
      #   VNET_SAMBA_SMBPASSWD   -> VNET_1_SAMBA_SMBPASSWD
      my $newid = $id;
      if ("$id" eq 'VNET_SAMBA') {
         next;
      } elsif ("$id" eq 'VNET_SAMBA_MACHINESID') {
         next;
      } elsif ("$id" eq 'VNET_SAMBA_SMBPASSWD') {
         next;
      } elsif ("$id" eq 'VNET_HOSTONLY') {
        $newid='VNET_1_HOSTONLY';
      } elsif ("$id" eq 'VNET_HOSTONLY_HOSTADDR') {
        $newid='VNET_1_HOSTONLY_HOSTADDR';
      } elsif ("$id" eq 'VNET_HOSTONLY_NETMASK') {
        $newid='VNET_1_HOSTONLY_NETMASK';
      } elsif ("$id" eq 'VNET_INTERFACE') {
        $newid='VNET_0_INTERFACE';
      }

      print INSTALLDB 'answer ' . $newid . ' ' . $gDBAnswer{$id} . "\n";
    }

    # For the rpm4|tar4 format, two keyword were added. We add them here if
    # necessary.  Note that it is only necessary to check the existence of two
    # VNET_HOSTONLY_ keywords since the rpm2|tar2 format contained only a few
    # VNET_ keywords
    my $addr = db_get_answer_if_exists('VNET_HOSTONLY_HOSTADDR');
    my $mask = db_get_answer_if_exists('VNET_HOSTONLY_NETMASK');
    if (defined($addr) and defined($mask)) {
       print INSTALLDB 'answer VNET_1_HOSTONLY_SUBNET ' .
                        compute_subnet($addr, $mask) . "\n";
       print INSTALLDB "answer VNET_1_DHCP yes\n";
    }

    db_save();
  } elsif ( $version == 3 ) {
    print wrap('Converting the ' . $intermediate_format
               . ' installer database format to the tar4 installer database format.'
               . "\n\n", 0);
    # Upgrade the database format: keep only the 'answer' statements, and add a
    # 'file' statement for the main database file
    my $id;

    db_load();
    if (not open(INSTALLDB, '>' . $gInstallerMainDB)) {
      error('Unable to open the tar installer database ' . $gInstallerMainDB
            . ' in write-mode.' . "\n\n");
    }
    db_add_file($gInstallerMainDB, 0);

    # No conversions necessary between version 3 and 4, so add all answers
    foreach $id (keys %gDBAnswer) {
      print INSTALLDB 'answer ' . $id . ' ' . $gDBAnswer{$id} . "\n";
    }

    # Check whether we need to add the two new keywords for each virtual network:
    #   VNET_n_HOSTONLY_SUBNET -> set if VNET_n_HOSTONLY_{HOSTADDR,NETMASK} are set
    #   VNET_n_DHCP            -> 'yes' iff VNET_n_INTERFACE is not defined and
    #                              VNET_n_HOSTONLY_{HOSTADDR,NETMASK} are defined
    #
    my $i;
    for ($i = $gMinVmnet; $i < $gMaxVmnet; $i++) {
      my $pre = 'VNET_' . $i . '_';
      my $interface = db_get_answer_if_exists($pre . 'INTERFACE');
      my $hostaddr  = db_get_answer_if_exists($pre . 'HOSTONLY_HOSTADDR');
      my $netmask   = db_get_answer_if_exists($pre . 'HOSTONLY_NETMASK');

      if (defined($hostaddr) && defined($netmask)) {
         my $subnet = compute_subnet($hostaddr, $netmask);
         print INSTALLDB 'answer ' . $pre . 'HOSTONLY_SUBNET ' . $subnet . "\n";

         if (not defined($interface)) {
            print INSTALLDB 'answer ' . $pre . "DHCP yes\n";
         }
      }
    }

    db_save();
  }

  db_load();
  db_append();
  if ($made_dir1) {
    db_add_dir($gRegistryDir);
  }
  if ($made_dir2) {
    db_add_dir($gStateDir);
  }
}

sub create_initial_database {
  my $made_dir1;
  undef %gDBAnswer;
  undef %gDBFile;
  undef %gDBDir;
  undef %gDBLink;
  undef %gDBMove;

  # This is the first installation. Create the installer database from
  # scratch
  print wrap('Creating a new ' . vmware_product_name()
             . ' installer database using the tar4 format.' . "\n\n", 0);

  $made_dir1 = create_dir($gRegistryDir, 0);
  safe_chmod(0755, $gRegistryDir);

  if (not open(INSTALLDB, '>' . $gInstallerMainDB)) {
    if ($made_dir1) {
      rmdir($gRegistryDir);
    }
    error('Unable to open the tar installer database ' . $gInstallerMainDB
          . ' in write-mode.' . "\n\n");
  }
  # Force a flush after every write operation.
  # See 'Programming Perl', p. 110
  select((select(INSTALLDB), $| = 1)[0]);

  if ($made_dir1) {
    db_add_dir($gRegistryDir);
  }
  # This file is going to be modified after its creation by this program.
  # Do not timestamp it
  db_add_file($gInstallerMainDB, 0);
}

# SIGINT handler. We will never reset the handler to the DEFAULT one, because
# with the exception of pre-uninstaller not being installed, this one does
# the same thing as the default (kills the process) and even sends the end
# RPC for us in tools installations.
sub sigint_handler {
  if ($gIsUninstallerInstalled == 0) {
    print STDERR wrap("\n\n" . 'Ignoring attempt to kill the installer with Control-C, because the uninstaller has not been installed yet. Please use the Control-Z / fg combination instead.' . "\n\n", 0);

    return;
  }

  error('');
}

#  Write the VMware host-wide configuration file - only if console
sub write_vmware_config {
  my $name;

  $name = $gRegistryDir . '/config';

  uninstall_file($name);
  if (file_check_exist($name)) {
    return;
  }
  # The file could be a symlink to another location. Remove it
  unlink($name);

  open(CONFIGFILE, '>' . $name) or error('Unable to open the configuration file '
                                         . $name . ' in write-mode.' . "\n\n");
  db_add_file($name, 0x1);
  safe_chmod(0444, $name);
  print CONFIGFILE 'libdir = "' . db_get_answer('LIBDIR') . '"' . "\n";
  close(CONFIGFILE);
}

# Get the installed version of VMware
# Return the version if found, or ''
sub get_installed_version() {
  my $backslash;
  my $dollar;
  my $pattern;
  my $version;
  my $nameTag;

  # XXX In the future, we should use a method of the installer object to
  #     retrieve the installed version

  #
  # Try to retrieve the installed version from the configurator program. This
  # works for both the tar and the rpm installers
  #

  if (not defined($gDBAnswer{'BINDIR'})) {
    return '';
  }

  if (not open(FILE, '<' . db_get_answer('BINDIR') . $gConfigurator)) {
    return '';
  }

  # Build the pattern without using the dollar character, so that CVS doesn't
  # modify the pattern in tagged builds (bug 9303)
  $backslash = chr(92);
  $dollar = chr(36);
  $pattern = '^  ' . $backslash . $dollar . 'buildNr = ' .
      "'" . '(\S+) ' . "'" . ' ' . $backslash . '. q' .
      $backslash . $dollar . 'Name: (\S+)? ' . $backslash . $dollar . ';' . $dollar;

  $version = '';
  $nameTag = '';
  while (<FILE>) {
    if (/$pattern/) {
      $version = $1;
      $nameTag = defined($2) ? $2 : '';
    }
  }
  close(FILE);

  return $version;
}

# Get the installed kind of VMware
# Return the kind if found, or ''
sub get_installed_kind() {
  my $kind;

  if (not (-x $cInstallerObject)) {
    return '';
  }

  $kind = direct_command(shell_string($cInstallerObject) . ' kind');
  chop($kind);

  return $kind;
}

# Install the content of the module package
sub install_module {
  my %patch;

  print wrap('Installing the kernel modules contained in this package.' . "\n\n", 0);

  undef %patch;
  install_dir('./lib', db_get_answer('LIBDIR'), \%patch, 0x1);
}

# Uninstall modules
sub uninstall_module {
  print wrap('Uninstalling currently installed kernel modules.' . "\n\n", 0);

  uninstall_prefix(db_get_answer('LIBDIR') . '/modules');
}

# XXX Duplicated in config.pl
# format of the returned hash:
#          - key is the system file
#          - value is the backed up file.
# This function should never know about filenames. Only database
# operations.
sub db_get_files_to_restore {
  my %fileToRestore;
  undef %fileToRestore;
  my $restorePrefix = 'RESTORE_';
  my $restoreBackupSuffix = '_BAK';
  my $restoreBackList = 'RESTORE_BACK_LIST';

  if (defined db_get_answer_if_exists($restoreBackList)) {
    my $restoreStr;
    foreach $restoreStr (split(/:/, db_get_answer($restoreBackList))) {
      if (defined db_get_answer_if_exists($restorePrefix . $restoreStr)) {
        $fileToRestore{db_get_answer($restorePrefix . $restoreStr)} =
          db_get_answer($restorePrefix . $restoreStr
                        . $restoreBackupSuffix);
      }
    }
  }
  return %fileToRestore;
}

# Returns an array with the list of files that changed since we installed
# them.
sub db_is_file_changed {

  my $file = shift;
  my @statbuf;

  @statbuf = stat($file);
  if (defined $gDBFile{$file} && $gDBFile{$file} ne '0' &&
      $gDBFile{$file} ne $statbuf[9]) {
    return 'yes';
  } else {
    return 'no';
  }
}

sub filter_out_bkp_changed_files {

  my $filesToRestoreRef = shift;
  my $origFile;

  foreach $origFile (keys %$filesToRestoreRef) {
    if (db_file_in($origFile) && !-l $origFile &&
        db_is_file_changed($origFile) eq 'yes') {
      # We are in the case of bug 25444 where we are restoring a file
      # that we backed up and was changed in the mean time by someone else
      db_remove_file($origFile);
      backup_file($$filesToRestoreRef{$origFile});
      unlink $$filesToRestoreRef{$origFile};
      print wrap("\n" . 'File ' . $$filesToRestoreRef{$origFile}
                 . ' was not restored from backup because our file '
                 . $origFile
                 . ' got changed or overwritten between the time '
                 . vmware_product_name()
                 . ' installed the file and now.' . "\n\n"
                 ,0);
      delete $$filesToRestoreRef{$origFile};
    }
  }
}

sub restore_backedup_files {
  my $fileToRestore = shift;
  my $origFile;

  foreach $origFile (keys %$fileToRestore) {
    if (file_name_exist($origFile) &&
        file_name_exist($$fileToRestore{$origFile})) {
      backup_file($origFile);
      unlink $origFile;
    }
    if ((not file_name_exist($origFile)) &&
        file_name_exist($$fileToRestore{$origFile})) {
      rename $$fileToRestore{$origFile}, $origFile;
    }
  }
}

# depmod_all_kernels
#
# Runs depmod on all installed kernels on the system.
sub depmod_all_kernels {
   my $depmodBin = shell_string($gHelper{'depmod'});

   foreach my $kRel (internal_ls('/lib/modules/')) {
      # Check if the modules.dep file exists.  If so, then
      # rebuild modules.dep for that kernel.
      my $depmodPath = "/lib/modules/$kRel/modules.dep";
      if (-f $depmodPath) {
	 system(join(' ', $depmodBin, '-a', $kRel));
      }
   }
}

# The initrd in place includes modules we added on configure.  If the module
# files containing references to these modules have been restored then simply
# remaking the initrd will put it back into original condition.
sub restore_kernel_initrd {
  my $cmd = db_get_answer_if_exists('RESTORE_RAMDISK_CMD');

  if (defined($cmd)) {
     # Rebuild all the system modules.dep files to reflect
     # us ripping out all of the kernel modules.
     depmod_all_kernels();

     my $kernListStr = db_get_answer_if_exists('RESTORE_RAMDISK_KERNELS');
     my $oneCall = db_get_answer_if_exists('RESTORE_RAMDISK_ONECALL');
     if ($oneCall) {
        if (system(join(' ', $cmd, '>/dev/null 2>&1')) != 0) {
           # Check to ensure that the command succeded.  If it didn't the system may
           # not boot.  We need to error out if that is the case.
           error( wrap("ERROR: \"$cmd\" exited with non-zero status.\n" .
                       "\n" .
                       'Your system currently may not have a functioning init ' .
                       'image and may not boot properly.  DO NOT REBOOT!  ' .
                       'Please ensure that you have enough free space available ' .
                       "in your /boot directory and run this command: \"$cmd\" " .
                       "again.\n\n", 0));

        }

     } elsif ($kernListStr) {
        my @kerns = split(/,/, $kernListStr);

        # Now for each kernel in our list, run the initrd restore command on it
        foreach my $kern (@kerns) {
           next unless (-e "/lib/modules/$kern/modules.dep");
           my $fullCmd = $cmd;
           $fullCmd =~ s/KREL/$kern/g;
           if (system(join(' ', $fullCmd, '>/dev/null 2>&1')) != 0) {
              error( wrap("ERROR: \"$fullCmd\" exited with non-zero status.\n" .
                          "\n" .
                          'Your system currently may not have a functioning init ' .
                          'image and may not boot properly.  DO NOT REBOOT!  ' .
                          'Please ensure that you have enough free space available ' .
                          "in your /boot directory and run this command: \"$fullCmd\" " .
                          "again.\n\n", 0));
           }
        }
     } else {
        error("RESTORE_RAMDISK parameters were not properly set.\n");
     }
     # Now reset all the answers
     db_remove_answer('RESTORE_RAMDISK_CMD');
     db_remove_answer('RESTORE_RAMDISK_KERNELS');
     db_remove_answer('RESTORE_RAMDISK_ONECALL');
  }
}


##
# unset_kmod_db_entries
#
# Iterates through the database and unsets kmod specific DB entries.  This
# function is called at uninstall time since these modules are deleted as
# part of the uninstall.  Yes I know I could do this faster...  whatev.
#
sub unset_kmod_db_entries {
   foreach my $kmod (@cKernelModules) {
      my $regexp = '^' . uc($kmod) . '_.+_(PATH|NAME)';
      foreach my $key (keys %gDBAnswer) {
         db_remove_answer($key) if ($key =~ m/$regexp/);
      }
   }
}


##
# deconfigure_updatedb
#
# Deconfigures updatedb.conf.  Removes hgfs entry from PRUNEFS.
#
sub deconfigure_updatedb {
   my $file = db_get_answer_if_exists('UPDATEDB_CONF_FILE');

   return 0 unless ($file and -e $file);

   my $key =  db_get_answer('UPDATEDB_CONF_KEY');
   db_remove_answer('UPDATEDB_CONF_FILE');
   db_remove_answer('UPDATEDB_CONF_KEY');

   my $regex = '^\s*(' . $key . '\s*=\s*")(.*)(")$';
   my $delim = ' ';
   my $entry = 'vmhgfs';
   return removeTextInKVEntryInFile($file, $regex, $delim, $entry);
}

##
# deconfigure_initrd_suse
#
# deconfigures /etc/sysconfig/kernel
#
sub deconfigure_initrd_suse {
   my $file = db_get_answer_if_exists('INITRDMODS_CONF_FILE');

   return 0 unless ($file and -e $file);

   my $key =  db_get_answer('INITRDMODS_CONF_KEY');
   my $vals =  db_get_answer_if_exists('INITRDMODS_CONF_VALS');

   # this should never hit, but just in case
   if (not defined $vals) {
      print wrap("warning: could not INITRDMODS_CONF_VALS value in locations db.\n\n", 0);

      db_remove_answer('INITRDMODS_CONF_FILE');
      db_remove_answer('INITRDMODS_CONF_KEY');
      return 0;
   }

   # put the space-delimited kmods in an array
   my @splitVals = split(' ', $vals);

   my $regex = '^\s*(' . $key . '\s*=\s*")(.*)(")$';
   my $delim = ' ';

   # removing all of the initrd kmods from the initrd file requires
   # a loop because of the logic in removeTextInKVEntryInFile
   foreach my $val (@splitVals) {
      removeTextInKVEntryInFile($file, $regex, $delim, $val);
   }

   db_remove_answer('INITRDMODS_CONF_FILE');
   db_remove_answer('INITRDMODS_CONF_KEY');
   db_remove_answer('INITRDMODS_CONF_VALS');

}

##
# deconfigure_dracut
#
# deconfigures /etc/dracut.conf
#
sub deconfigure_dracut {
   my $file = db_get_answer_if_exists('INITRDMODS_CONF_FILE');

   return 0 unless ($file and -e $file);

   # we only deconfigure dracut.conf because /etc/dracut.conf.d/vmware-tools.conf
   # should be removed through the normal uninstallation routes (i.e., it will be removed)
   if ($file eq '/etc/dracut.conf') {
      # Then we have to deconfigure it inline (should only need on fedora 12).
      my $key = db_get_answer_if_exists('INITRDMODS_CONF_KEY');
      my $vals = db_get_answer_if_exists('INITRDMODS_CONF_VALS');

      if (not $key or not $vals) {
         print wrap("warning: Unable to find $key or $vals in locations database.\n\n", 0);
         return 0;
      }

      # put the space-delimited kmods in an array
      my @splitVals = split(' ', $vals);

      my $regex = '^\s*(' . $key . '\s*\+=\s*")(.*)(")$';
      my $delim = ' ';

      # removing all of the initrd kmods from the initrd file requires
      # a loop because of the logic in removeTextInKVEntryInFile
      foreach my $val (@splitVals) {
         removeTextInKVEntryInFile($file, $regex, $delim, $val);
      }

      db_remove_answer('INITRDMODS_CONF_KEY');
      db_remove_answer('INITRDMODS_CONF_VALS');

   } elsif($file eq '/etc/dracut.conf.d/vmware-tools.conf') {
      # do nothing because this file will be (or has already been) removed
      # via our normal uninstallation routes (i.e., uninstaller goes through
      # the installed files and removes them one by one).
   } else {
      print wrap("warning: Unable to deconfigure dracut.\n", 0);
   }

   # remove the answer regardless
   db_remove_answer('INITRDMODS_CONF_FILE');
}

##
# deconfigure_initmodfile
#
# Deconfigures the suse or dracut style initrd mechanisms
# (/etc/sysconfig/kernel or /etc/dracut.conf)
# deconfigure_dracut() defers Fedora 13+ .d style configurations
# to the normal uninstall mechanisms (removing the
# /etc/dracut.conf.d/vmware-tools.conf file)
#
sub deconfigure_initmodfile {
   if (-e '/etc/SuSE-release') { # same logic we use to determine distribution in config.pl
      deconfigure_initrd_suse();
   } elsif (internal_which('dracut') ne '') {
      deconfigure_dracut();
   }
}


#
# For files modified with block_append(), rather than restoring a backup file
# remove what was appended.  This will preserve any changes a user may have made
# to these files after install/config ran.
sub restore_appended_files {
   my $list = '';

   $list = db_get_answer_if_exists('APPENDED_FILES');
   if (not defined($list)) {
      return;
   }

   foreach my $file (split(':', $list)) {
      if (-f $file) {
         block_restore($file, $cMarkerBegin, $cMarkerEnd);
      }
   }
}

### Finalize this ACE package so it can be used.
sub acevm_finalize {
  my $vmxPath = acevm_find_vmx($gRegistryDir);
  my $ret;
  if ($vmxPath eq '') {
    error('Failed. Can\'t find VMX file for this package' . "\n\n");
  }
  $ret = system(shell_string($gHelper{'vmware-acetool'}) . ' finalizePolicies '
		. shell_string($vmxPath));
  return (($ret >> 8) == 0);
}

### Check to see if the passed in instance has the same ace id as this update package
sub acevm_checkMasterID {
  my $vmxPath = shift;
  my $exitValue;

  if ($vmxPath eq '') {
    error('Failed. Can\'t find vmx file for this package' . "\n\n");
  }
  system(shell_string($gHelper{'vmware-acetool'}) . ' checkMasterID '
	 . shell_string($vmxPath) . ' ' . shell_string($gManifest{'aceid'})
	 . '> /dev/null 2>&1');
  $exitValue = $? >> 8;
  return $exitValue == 0;
}

### Check to see if "now" falls outside this package's valid date range.
sub acevm_check_valid_date {
  my $now = time();
  my $ret = 1;
  if (!defined($gManifest{'validFrom'})) {
    $gManifest{'validFrom'} = 0;
  }
  if (!defined($gManifest{'validTo'})) {
    $gManifest{'validTo'} = 0;
  }

  # Default to returning true. Return false only if either of the
  # following is true:
  #   - 'from' is valid and we're not there yet.
  #   - 'to' is valid and we've already passed it.
  if ($gManifest{'validFrom'} > 0 && $gManifest{'validFrom'} > $now) {
    $ret = 0;
  } elsif ($gManifest{'validTo'} > 0 && $gManifest{'validTo'} < $now) {
    $ret = 0;
  }

  return $ret;
}

### Find the vmx file for this package.
sub acevm_find_vmx {
  my $dir = shift;
  my $ret = '';
  my $file;

  opendir(DIR, $dir) or return '';

  while( defined ($file = readdir(DIR)) ) {
    if ($file =~ /^.+\.vmx$/) {
      $ret = $file;
      last;
    }
  }
  close DIR;
  if ($ret ne '') {
    $ret = $dir . '/' . $ret;
  }
  return $ret;
}

### Check if this ace instance is running.
### We do this by pattern matching 'vmware-vmx' and the vmx filename in a single
### line of the 'ps -ef' output.
sub acevm_is_instance_running {
  my $line;
  my $found = 0;
  my $vmxFile = acevm_find_vmx($gRegistryDir);

  if ($vmxFile eq '') {
    return 0;
  }
  open(PSOUT, 'ps -ef|');
  while (<PSOUT>) {
    if (m/vmware-vmx.+$vmxFile/) {
      $found = 1;
      last;
    }
  }
  close(PSOUT);
  return $found;
}

# Create launcher (shortcuts) in the user's home directory.
sub acevm_create_desktop_icon {
   my $acename = shift;
   my $aceid = shift;
   my $file = shift;
   my %patch;
   my $homedir = get_home_dir();

   if (! $homedir) {
      print STDERR 'Unable to install shortcuts because the ' .
                   "home directory can't be found.\n\n";
      return;
   }

   # create base menu file structure
   create_dir($homedir . '/.local/share/applications', 0);

   # count number of packages from this ACE master
   my $count = 0;
   foreach $file (glob("$homedir/.local/share/applications/*.desktop")) {
      if ($file =~ /$gManifest{'aceid'}(.)*\.desktop$/) {
         $count++;
      }
   }
   $count = $count gt 0 ? " $count" : '';

   # create desktop entry
   my $DESKTOP;
   my $desktop_file_name = $aceid . $count . '.desktop';
   my $tmpdir = make_tmp_dir('vmware-installer');
   my $tmpfile = $tmpdir . '/' . $desktop_file_name;
   if (!open(DESKTOP, ">$tmpfile")) {
      print STDERR wrap("Unable to open file $tmpfile for writing.  You must either " .
                        "create the launcher by hand or launch the ACE VM directly.");
      remove_tmp_dir($tmpdir);
      return;
   }

   my $vmplayerFile = $gConfig->get('bindir') . '/vmplayer';
   my $vmx = acevm_find_vmx($gRegistryDir);
   print DESKTOP <<EOF;
[Desktop Entry]
Encoding=UTF-8
Type=Application
Icon=vmware-acevm
Exec=$vmplayerFile "$vmx"
Name=$acename$count
Categories=VirtualMachines;ACE;
EOF

   close(DESKTOP);
   my $desktop_dest = $homedir . "/.local/share/applications/$desktop_file_name";
   undef %patch;
   install_file($tmpfile, $desktop_dest, \%patch, 1);
   remove_tmp_dir($tmpdir);
}

### Does the dstDir have enough space to hold srcDir
sub check_disk_space {
  my $srcDir = shift;
  my $dstDir = shift;
  my $srcSpace;
  my $dstSpace;
  my @parser;

  # get the src usage
  open (OUTPUT, shell_string($gHelper{'du'}) . ' -sk ' . shell_string($srcDir)
	. ' 2>/dev/null|') or error("Failed to open 'du'.");
  $_ = <OUTPUT>;
  @parser = split(/\s+/);
  $srcSpace = $parser[0];
  close OUTPUT;

  # Before we can check the space, $dst must exist. Walk up the directory path
  # until we find something that exists.
  while (! -d $dstDir) {
    $dstDir = internal_dirname($dstDir);
  }
  open (OUTPUT, shell_string($gHelper{'df'}) . ' -k ' .  shell_string($dstDir)
	. ' 2>/dev/null|');
  while (<OUTPUT>) {
    @parser = split(/\s+/);
    if ($parser[0] ne 'Filesystem') {
      $dstSpace = $parser[3];
    }
  }
  close OUTPUT;

  # Return the amount of space available in kbytes.
  return ($dstSpace - $srcSpace);
}

sub check_for_xen {
   if ((not -d '/proc/xen') ||
       (not -e '/proc/xen/capabilities') ||
       (not open(XEN, '/proc/xen/capabilities'))) {
      return 0;
   }
   my $isXen = 0;
   while (<XEN>) {
      if ($_ =~ /\w+/) {
         $isXen++;
         last;
      }
   }
   close(XEN);
   if ($isXen == 0) {
      return 0;
   }

   # Must be a xen system.
   return 1;
}

### Does the user have permission to write to this directory?
sub check_dir_writeable {
  my $dstDir = shift;

  # Before we can check the permission, $dst must exist. Walk up the directory path
  # until we find something that exists.
  while (! -d $dstDir) {
    $dstDir = internal_dirname($dstDir);
  }

  # Return whether this directory is writeable.
  return (-w $dstDir);
}

#
#  Check to see that the product architecture is a mismatch for this os.
#  Return an error string if there is a mismatch, otherwise return undef
#
sub product_os_match {

  init_product_arch_hash();
  if (!defined($multi_arch_products{vmware_product()})) {
    return undef;
  }

  if (is64BitUserLand() == (vmware_product_architecture() eq "x86_64")) {
    return undef;
  }
  if (is64BitUserLand() != (vmware_product_architecture() ne "x86_64")) {
    return undef;
  }

  return sprintf('This version of "%s" is incompatible with this '
		. 'operating system.  Please install the "%s" '
		. 'version of this program instead.'
		. "\n\n", vmware_product_name(),
		  is64BitUserLand() ? 'x86_64' : 'i386');
}

#
#  Create a list of products that support both a 32bit and a 64bit
#  architecture and thus should be matched to the running OS.
#
sub init_product_arch_hash {
  $multi_arch_products{'ws'} = 1;
  $multi_arch_products{'wgs'} = 1;
  $multi_arch_products{'vix'} = 1;
  $multi_arch_products{'api'} = 1;
  $multi_arch_products{'vicli'} = 1;
}

# Look for the location of an answer in a different database and return the
# the value or the empty string if no answer or file is found.
sub alt_db_get_answer  {
  my $db_file = shift;
  my $key = shift;
  my $answer = '';

  if (open(PLAYERINSTALLDB, '<' . $db_file)) {
    while (<PLAYERINSTALLDB>) {
      chomp;
      if (/^answer\s+$key\s+(.+)$/) {
        $answer = $1;
      } elsif (/^remove_answer\s+$key\s*$/) {
          $answer = '';
      }
    }
    close(PLAYERINSTALLDB);
  }
  return $answer;
}
# Program entry point
sub main {
   my (@setOption, $opt);
   my $chk_msg;
   my $originalPath;
   my $progpath = $0;
   my $scriptname = internal_basename($progpath);

   if ((vmware_product() eq 'tools-for-linux' ||
        vmware_product() eq 'tools-for-freebsd' ||
        vmware_product() eq 'tools-for-solaris')
       && !DoesOSMatchProduct()) {
       error(vmware_longname() . ' will not install on the operating system you are ' .
	    'running. Please be sure you install the version of ' .
	    vmware_product_name() . ' that is appropriate for your operating system.' .
	    "\n\n");
   }

   $chk_msg = product_os_match();
   if (defined($chk_msg)) {
     error($chk_msg);
   }

   if (vmware_product() ne 'acevm' && !is_root()) {
     error('Please re-run this program as the super user.' . "\n\n");
   }

   # Force the path to reduce the risk of using "modified" external helpers
   # If the user has a special system setup, he will will prompted for the
   # proper location anyway
   $originalPath = $ENV{'PATH'};
   $ENV{'PATH'} = '/bin:/usr/bin:/sbin:/usr/sbin';

   initialize_globals(internal_dirname($0));
   initialize_external_helpers();

   # List of questions answered with command-line arguments
   @setOption = ();

   if (internal_basename($0) eq $cInstallerFileName) {
     my $answer;

     if ($#ARGV > -1) {
       # There are only two possible arguments
       while ($#ARGV != -1) {
         my $arg;
         $arg = shift(@ARGV);

         if (lc($arg) =~ /^(-)?(-)?d(efault)?$/) {
           $gOption{'default'} = 1;
         } elsif (lc($arg) =~ /^--clobber-kernel-modules=([\w,]+)$/) {
           $gOption{'clobberKernelModules'} = "$1";
	 } elsif (lc($arg) =~ /^(-)?(-)?nested$/) {
           $gOption{'nested'} = 1;
         } elsif (lc($arg) =~ /^-?-?prefix=(.+)/) {
           $gOption{'prefix'} = $1;
         } elsif ($arg =~ /=yes/ || $arg =~ /=no/) {
           push(@setOption, $arg);
         } elsif (lc($arg) =~ /^(-)?(-)?(no-create-shortcuts)$/) {
           $gOption{'create_shortcuts'} = 0;
         } else {
           install_usage();
         }
       }
     }

    if (-e '/etc/vmware/database' && (vmware_product() eq 'ws' ||
                                      vmware_product() eq 'wgs')) {
         error("An incompatible VMware product is already installed on this " .
               "machine.  You must uninstall it by running vmware-uninstall.\n\n");
    } elsif (-e '/etc/vmware-vix/database' && vmware_product() eq 'vix') {
        error("An incompatible VMware product is already installed on this " .
              "machine.  You must uninstall it by running vmware-uninstall-vix.\n\n");
    }

     # Other installers will be able to remove this installation cleanly only if
     # they find the uninstaller. That's why we:
     # . Install the uninstaller ASAP
     # . Prevent users from playing with Control-C while doing so

    $gIsUninstallerInstalled = 0;

    # Install the SIGINT handler. Don't bother resetting it, see
    # sigint_handler for details.
    $SIG{INT} = \&sigint_handler;
    $SIG{QUIT} = \&sigint_handler;

    # Tell the Host that the installer for tools is now
    # active.
    if (vmware_product() eq 'tools-for-linux' ||
	vmware_product() eq 'tools-for-freebsd' ||
	vmware_product() eq 'tools-for-solaris') {
      send_rpc("toolinstall.installerActive 1");
    }

    # Check for open-vm-tools and related packages before we install
    # tools-for-linux.
    if (vmware_product() eq 'tools-for-linux') {
       my @debPkgs = checkDPKGForPackages(@cOpenVMToolsDEBPackages);
       my @rpmPkgs = checkRPMForPackages(@cOpenVMToolsRPMPackages);

       if (@debPkgs or @rpmPkgs) {

          my $ans = get_answer('open-vm-tools are installed on this '.
                               'system. Do you want to continue a '.
                               'minimal installation of VMware tools? '.
                               'Otherwise the packages '. join(', ', @debPkgs, @rpmPkgs) .
                               ' need to be removed.',
                               'yesno', 'yes');

          if ($ans ne 'yes') {
            my $ans = get_answer('Do you want the installer to remove these packages now? '.
                                 'Answer \'yes\' to remove, or \'no\' to exit.', 'yesno', ''); 
            if ($ans eq 'yes') {
              if (@rpmPkgs and removeRPMPackages(@rpmPkgs) ne 0) {
                error("Failed to remove the following packages:\n\n" .
                  join("\n", @rpmPkgs) .
                    "\n\nPlease manually remove them before " .
                    "installing VMware Tools.\n\n");
              }

              if (@debPkgs and removeDEBPackages(@debPkgs) ne 0) {
                error("Failed to remove the following packages:\n\n" .
                  join("\n", @debPkgs) .
                    "\n\nPlease manually remove them before " .
                    "installing VMware Tools.\n\n");
              }

              # The open-vm tools don't always unload the modules properly.
              # The init script won't unload them either because the modules
              # havent been configured yet when the vmware-tools service
              # stops.  Hence we need to unload them all manually now so our
              # service will start properly after running config.pl for
              # the first time.
              foreach my $mod (@cKernelModules) {
                foreach my $modDep ($cKernelModuleDeps{"$mod"}) {
                  kmod_unload($modDep, 0) if defined $modDep;
                }
                kmod_unload($mod, 0);
              }
            } else {
              exit 0;
            }
          } else {
            $open_vm_compat = 1;
          }
       }
    }

    # Don't allow installation of tools-for-solaris unless this is Solaris 9
    # or later and 32-bit (for now).  Note that we only officially support
    # Solaris 10 Update 1 and higher, but we'll allow users to install on 9.
    if (vmware_product() eq 'tools-for-solaris') {
      my $solVersion = direct_command(shell_string($gHelper{'uname'}) . ' -r');
      chomp($solVersion);
      my ($major, $minor) = split /\./, $solVersion; # / Fix emacs fontification

      if ($major != 5 || $minor < 9) {
        error('VMware Tools for Solaris is only supported on Solaris 10 and later.'
              . "\n\n");
      }

      # Warn users that we don't support Solaris 9, but they can install
      if ($minor == 9) {
        if (get_answer('WARNING: VMware Tools for Solaris is officially supported '
                       . 'on Solaris 10 and later, but you are running Solaris 9.  '
                       . 'Would you like to continue with the installation?',
                       'yesno', 'yes') eq 'no') {
           error('You have selected to not install VMware Tools for Solaris on '
                 . 'Solaris 9.' . "\n\n");
        }
      }
    }
    if (vmware_product() eq 'tools-for-solaris' ||
        vmware_product() eq 'tools-for-linux'   ||
        vmware_product() eq 'tools-for-freebsd') {
      if (-e $dspMarkerFile) {
        error('VMware Tools cannot be installed, since they have already ' .
              'been installed using a package-based mechanism (rpm or deb) ' .
              'on this system. If you wish to continue, you must first ' .
              'remove the currently installed VMware Tools using the '.
              'appropriate packaged-based mechanism, and then restart this ' .
              'installer' . "\n\n");
      }
    }

      if (vmware_product() ne 'tools-for-linux' &&
          vmware_product() ne 'tools-for-freebsd' &&
          vmware_product() ne 'tools-for-solaris') {

            # If the product is not tools, we need to bail on detecting a xen kernel.
	    if ( -d '/proc/xen' ) {
            	error('You cannot install ' .
                  vmware_product_name() .
                  ' on a system running a xen kernel.');
      }
   }

    # The uninstall of legacy tools must come before get_initial_database()
    if (vmware_product() eq 'tools-for-linux' ||
        vmware_product() eq 'tools-for-freebsd') {
      uninstall_content_legacy_tools();
    }

    if ( $progpath =~ /(.*?)\/$scriptname/ ) {
      chdir($1);
    }

    # The acevm install puts all files for a given install, including the installdb,
    # under a single directory.
    if (vmware_product() eq 'acevm') {
      my $answer = undef;
      my $home = get_home_dir() ||
                 error("Can't find home directory, unable to continue.\n\n");

      #
      # Check valid range for this package
      #
      if (!acevm_check_valid_date()) {
         error('This setup program cannot continue. This ACE can only be ' .
               'installed during its valid time period.' . "\n\n");
      }

      $gHelper{'vmware-acetool'} = acevm_find_acetool();
      if ($gHelper{'vmware-acetool'} eq '' || acevm_included_player_newer()) {
         print STDERR wrap('This setup program requires that the included VMware ' .
                           'Player must be installed with this ACE.' . "\n\n", 0);
         if (acevm_install_vmplayer()) {
           load_config(); # reload /etc/vmware/config
           $gHelper{'vmware-acetool'} = acevm_find_acetool();
         }
         else {
            error('VMware Player installation failed.  Please install manually then '.
                  'run setup again.');
         }
      }

      $gHelper{'vmware-config.pl'} = internal_dirname($gHelper{'vmware-acetool'}) .
                                                     '/vmware-config.pl';
      if (acevm_package_has_host_policies()) {
         if (!is_root()) {
            error ('This package specifies host policies and must be installed by a ' .
                   'system administrator. Try running this setup program with sudo or ' .
                   'contact your system administrator for help.' . "\n\n");
      } elsif (!acevm_can_install_host_policies()) {
            error('This package contains a host policies file, but there is already ' .
                  'a host policies file from another package installed. ' .
                  'Unable to continue' . "\n\n");
         }
      }
      my $rootdir = $home . '/vmware-ace/' . $gManifest{'acename'};
      if ($gACEVMUpdate) {
        $answer = acevm_get_updatedir($rootdir);
      } else {
        $answer = acevm_get_dir($rootdir);
      }

      if ($answer eq '') {
        error ('Cannot get install directory. Unable to contine.' . "\n\n");
      }
      $gRegistryDir= $answer;
      $gStateDir = $gRegistryDir . '/state';
      $gInstallerMainDB = $gRegistryDir . '/locations';
      $gInstallerObject = $gRegistryDir . '/installer.sh';
      $gConfFlag = $gRegistryDir . '/not_configured';
    }
    if (vmware_product() eq 'acevm' && file_name_exist($gInstallerMainDB)) {
      db_load();
      db_append();
    } else {
      # if a nested install, it is the responsibility of the parent to
      # make sure no conflicting products are installed
      if ($gOption{'nested'} != 1) {
       # prompt_and_uninstall_conflicting_products();
      }
      my $dstDir = $gRegistryDir;
      $gFirstCreatedDir = $dstDir;
      while (!-d $dstDir) {
        $gFirstCreatedDir = $dstDir;
        $dstDir = internal_dirname($dstDir);
      }
      get_initial_database();
      # Binary wrappers can be run by any user and need to read the
      # database.
      safe_chmod(0644, $gInstallerMainDB);
    }

    if($open_vm_compat) {
      db_add_answer('OPEN_VM_COMPAT', 'yes');
    } else {
      db_add_answer('OPEN_VM_COMPAT', 'no');
    }


    db_add_answer('INSTALL_CYCLE', 'yes');

    foreach $opt (@setOption) {
      my ($key, $val);
      ($key, $val) = ($opt =~ /^([^=]*)=([^=]*)/);
      db_add_answer($key, $val);
    }

    if (vmware_product() eq 'api') {
      my $previous = $gOption{'default'};
      $gOption{'default'} = 0;
      show_EULA();
      $gOption{'default'} = $previous;
    }

    install_or_upgrade();

    if (vmware_product() eq 'ws' || vmware_product() eq 'tools-for-linux') {
       configure_gtk2();
    }

    # Reset these answers in case we have installed new versions of these
    # documents.
    if (vmware_product() ne 'ws') {
      db_remove_answer('EULA_AGREED');
      db_remove_answer('ISC_COPYRIGHT_SEEN');
    }
    if (vmware_product() eq 'vix') {
      print wrap('Enjoy,' . "\n\n" . '    --the VMware team' . "\n\n", 0);
      exit 0;
    }

    if (vmware_product() ne 'api' && vmware_product() ne 'acevm' &&
        vmware_product() ne 'nvdk' &&
        vmware_product() ne 'vix-disklib') {
      if (file_name_exist($gConfFlag)) {
        $answer = get_persistent_answer('Before running '
                                        . vmware_product_name()
                                        . ' for the first time, you need to '
                                        . 'configure it by invoking the '
                                        . 'following command: "'
                                        . db_get_answer('BINDIR')
                                        . '/' . "$gConfigurator" . '". Do you '
                                        . 'want this program to invoke the '
                                        . 'command for you now?'
                                        , 'RUN_CONFIGURATOR', 'yesno', 'yes');
      } else {
        if (vmware_product() ne 'vix') {
          print wrap('Before running ' . vmware_product_name() . ' for the '
                     . 'first time, you need to configure it by invoking the'
                     . ' following command: "' . db_get_answer('BINDIR')
                     . '/' . "$gConfigurator" . '"' . "\n\n", 0);
        }
        $answer = 'no';
      }
    }

    db_save();

    my $configResult;

    if ((vmware_product() ne 'api') && (vmware_product() ne 'acevm') &&
        (vmware_product() ne 'nvdk') &&
        ((vmware_product() ne 'vix-disklib')) &&
        ($answer eq 'yes')) {
      my $defaultOpt = ($gOption{'default'} == 1) ? ' --default' : '';
      $defaultOpt .= defined($gOption{'prefix'}) ? ' --prefix'
                     . '=' . $gOption{'prefix'} : '';

      # Pass in the clobber kernel modules option if necessary.
      if (defined $gOption{'clobberKernelModules'}) {
	$defaultOpt .= ' --clobber-kernel-modules=' .
	  $gOption{'clobberKernelModules'};
      }

      # If we're the tools installer, forego sending the end RPC and let
      # the configurator do it.
      my $rpcOpt = (vmware_product() eq 'tools-for-linux' ||
		    vmware_product() eq 'tools-for-freebsd' ||
		    vmware_product() eq 'tools-for-solaris') ?
		    ' --rpc-on-end' : '';

      my $shortcutOpt = $gOption{'create_shortcuts'} ? '' : ' --no-create-shortcuts';

      # restore the user's original PATH before running the configurator
      $ENV{'PATH'} = $originalPath;

      # Catch error result to see if configurator died abnormally.
      $configResult = system(shell_string(db_get_answer('BINDIR') .
					  '/' . $gConfigurator) .
			     $defaultOpt . $rpcOpt . $shortcutOpt . ' --preserve');
    } else {
      print wrap('Enjoy,' . "\n\n" . '    --the VMware team' . "\n\n", 0);
    }

    if (vmware_product() eq 'tools-for-linux') {
      # For the fix to bug 304998, we are removing the hard-coded vmhgfs
      # entry from /etc/fstab, and instead mounting/unmounting dynamically
      # from the tools init script at startup/shutdown respectively. This
      # allows the init script to check for certain conditions (e.g., not
      # running on ESX) before deciding to do the mount.
      block_restore('/etc/fstab', $cMarkerBegin, $cMarkerEnd);
    }

    # Tell the Host that the installer for tools is now
    # active.
    if (vmware_product() eq 'tools-for-linux' ||
	vmware_product() eq 'tools-for-freebsd' ||
	vmware_product() eq 'tools-for-solaris') {
      send_rpc("toolinstall.installerActive 0");
    }

    exit 0;
  }

  #
  # Module updater.
  #
  # XXX This is not clean. We really need separate packages, managed
  #     by the VMware package manager
  #

  if (internal_basename($0) eq $cModuleUpdaterFileName) {
    my $installed_version;
    my $installed_kind;
    my $answer;

    print wrap('Looking for a currently installed '
               . vmware_longname() . ' tar package.' . "\n\n", 0);

    if (not (-e $cInstallerMainDB)) {
      error('Unable to find the ' . vmware_product_name() .
      ' installer database file (' . $cInstallerMainDB . ').' .
      "\n\n" . 'You may want to re-install the ' .
      vmware_longname() . ' package, then re-run this program.' . "\n\n");
    }
    db_load();

    $installed_version = get_installed_version();
    $installed_kind = get_installed_kind();

    if (not (($installed_version eq '5.1.4') and
             ($installed_kind eq 'tar'))) {
      error('This ' . vmware_product_name()
            . ' Kernel Modules package is intended to be used in conjunction '
            . 'with the ' . vmware_longname() . ' tar package only.' . "\n\n");
    }

    # All module files are under LIBDIR
    if (not defined($gDBAnswer{'LIBDIR'})) {
       error('Unable to determine where the ' . vmware_longname()
       . ' package installed the library files.' . "\n\n"
       . 'You may want to re-install the ' . vmware_product_name() . ' '
       . vmware_version() . ' package, then re-run this program.' . "\n\n");
    }

    db_append();
    uninstall_module();
    install_module();

    print wrap('The installation of ' . vmware_product_name()
               . ' Kernel Modules '
               . vmware_version() . ' completed successfully.' . "\n\n", 0);

    if (-e $cConfFlag) {
       $answer = get_persistent_answer('Before running the VMware software for '
                                       . 'the first time after this update, you'
                                       . ' need to configure it for your '
                                       . 'running kernel by invoking the '
                                       . 'following command: "'
                                       . db_get_answer('BINDIR')
                                       . '/' . $gConfigurator . '". Do you want this '
                                       . 'program to invoke the command for you now?',
                                       'RUN_CONFIGURATOR', 'yesno', 'yes');
    } else {
      $answer = 'no';
    }

    db_save();

    if ($answer eq 'yes') {
       system(shell_string(db_get_answer('BINDIR') . '/' . $gConfigurator));
    } else {
       print wrap('Enjoy,' . "\n\n" . '    --the VMware team' . "\n\n", 0);
    }
    exit 0;
  }

  if (internal_basename($0) eq $gUninstallerFileName) {
    if (vmware_product() eq 'acevm') {
       print wrap("Uninstalling VMware ACE $gManifest{'acename'}...\n\n", 0);
    } else {
       print wrap('Uninstalling the tar installation of ' .
       vmware_product_name() . '.' . "\n\n", 0);
    }

    if ($#ARGV > -1) {
      @setOption = ();
      # There is currently only one option:  --upgrade.
      while ($#ARGV != -1) {
        my $arg;
        $arg = shift(@ARGV);
        if (lc($arg) =~ /^(-)?(-)?u(pgrade)?$/) {
           $gOption{'upgrade'} = 1;
        } elsif ($arg =~ /=yes/ || $arg =~ /=no/) {
            push(@setOption, $arg);
        }
      }
    }

    if (not (-e $gInstallerMainDB)) {
      error('Unable to find the tar installer database file (' .
      $gInstallerMainDB . ')' . "\n\n");
    }
    db_load();

    db_append();

    ### Begin check for non-VMware modules ###
    foreach $opt (@setOption) {
       my ($key, $val);
      ($key, $val) = ($opt =~ /^([^=]*)=([^=]*)/);
      delete $gDBAnswer{$key};
      db_add_answer($key, $val);
    }

    if (vmware_product() eq 'acevm') {
      # Check to see if it has been moved by seeing if BINDIR exists
      if (! -e db_get_answer('BINDIR')) {
         error('Cannot uninstall because this ACE has been moved from ' .
               "its original location.\n\n");
      }
      # Check to see if this instance has been copied
      # by comparing the device and inode of the BINDIR against
      # the directory this uninstaller is in.
      my ($aDev, $aIno) = stat(internal_dirname($progpath));
      my ($bDev, $bIno) = stat(db_get_answer('BINDIR'));
      if ($aIno != $bIno || $aDev != $bDev) {
         error ('Cannot uninstall because this ACE has been copied.' . "\n\n");
      } elsif (acevm_is_instance_running()) {
         error ('Cannot uninstall because this ACE appears to be running. ' .
                'Please close the running ACE and run this uninstaller again.' .
                "\n\n");
      } else {
         uninstall('/acevm');
      }
    } elsif (vmware_product() eq 'tools-for-linux' ||
             vmware_product() eq 'tools-for-freebsd' ||
             vmware_product() eq 'tools-for-solaris') {
      my %fileToRestore;

      # Clean up the module loader config file from vmxnet.
      if (vmware_product() eq 'tools-for-freebsd' &&
          defined db_get_answer_if_exists('VMXNET_CONFED') &&
          db_get_answer('VMXNET_CONFED') eq 'yes') {
        my $loader_conf = '/boot/loader.conf';
        my $tmp_dir;
        my $tmp; # / unconfuse emacs fontification
        $tmp_dir = make_tmp_dir('vmware-installer');
        $tmp = $tmp_dir . '/loader.conf';
        if (block_remove($loader_conf, $tmp, $cMarkerBegin, $cMarkerEnd) >= 0) {
          system(shell_string($gHelper{'mv'}) . ' -f ' . shell_string($tmp)
                 . ' '
                 . shell_string($loader_conf));
        }
        remove_tmp_dir($tmp_dir);
      }

      #
      # Legacy autostart hooks involved modifying system files, so we must manually
      # restore the VMware-added blocks.
      #
      if (vmware_product() =~ /^tools-for-(linux|freebsd|solaris)$/) {
         unconfigure_autostart_legacy($cMarkerBegin, $cMarkerEnd);
      }

      # Get the file names before they disappear from the database.
      %fileToRestore = db_get_files_to_restore();

      filter_out_bkp_changed_files(\%fileToRestore);

      if (db_get_answer('OPEN_VM_COMPAT') eq 'yes') {
        $open_vm_compat = 1
      }

      # Do the bulk of the file uninstallation. Pass in the (slightly)
      # different name for FreeBSD Tools so that they get stopped correctly.
      if (vmware_product() eq 'tools-for-freebsd') {
	uninstall('/vmware-tools.sh');
      } else {
	uninstall('/vmware-tools');
      }

      # Clean up drivers with rem_drv(1M) (corresponds to add_drv(1M) calls in
      # configure_module_solaris() in configure script).  This needs to happen
      # after the services are stopped in uninstall().
      if (vmware_product() eq 'tools-for-solaris') {
         if (defined db_get_answer_if_exists('VMXNET_CONFED') &&
             db_get_answer('VMXNET_CONFED') eq 'yes') {

            system(shell_string($gHelper{'rem_drv'}) . ' vmxnet');

            # Give pcn its claim on pci1022,2000 back
            if (direct_command(shell_string($gHelper{'uname'}) . ' -r') =~ 5.9) {
              # Try to add back the pcn driver we removed
              system(shell_string($gHelper{'add_drv'})
                     . ' -i \'"pci103c,104c" "pci1022,2000"\' pcn >/dev/null 2>&1');
            } else {
              system(shell_string($gHelper{'update_drv'}) . ' -a -i \'"pci1022,2000"\' '
                                  . 'pcn >/dev/null 2>&1');
            }
         }
         if (defined db_get_answer_if_exists('VMXNET3S_CONFED') &&
             db_get_answer('VMXNET3S_CONFED') eq 'yes') {
            system(shell_string($gHelper{'rem_drv'}) . ' vmxnet3s');
         }
         if (defined db_get_answer_if_exists('VMHGFS_CONFED') &&
             db_get_answer('VMHGFS_CONFED') eq 'yes') {
            my $devLinkTable = "/etc/devlink.tab";
            my $searchString = "name=vmhgfs";

            system(shell_string($gHelper{'rem_drv'}) . ' vmhgfs');

            if (system(shell_string($gHelper{'grep'}) . ' ' . $searchString
                       . ' ' . $devLinkTable . ' > /dev/null 2>&1') == 0) {
               # XXX There has to be a better way, but I don't know Perl
               my $tmpFile = "/tmp/VMware.devlink.tab";
               system(shell_string($gHelper{'cat'}) . ' ' . $devLinkTable . ' | '
                      . shell_string($gHelper{'grep'}) . ' -v ' . $searchString
                      . ' > ' . $tmpFile);
               system(shell_string($gHelper{'mv'}) . ' ' . $tmpFile . ' '
                      . $devLinkTable);
            }
         }
      }

      if (vmware_product() eq 'tools-for-linux') {
	if (defined db_get_answer_if_exists('VMHGFS_CONFED') &&
	    db_get_answer('VMHGFS_CONFED') eq 'yes') {
	  # remove the entries for the vmhgfs mount.
	  block_restore('/etc/fstab', $cMarkerBegin, $cMarkerEnd);
	}

	# If we modfified the ld.so cache during the install, we need to
	# run ldconfig here to ensure that the tools libraries are no
	# longer in the system library path.
	if (defined db_get_answer_if_exists('LD_DOT_SO_DOT_CONF_ADDED_FILE') or
	    defined db_get_answer_if_exists('LD_DOT_SO_DOT_CONF_MODIFIED')) {
	  #
	  # Check to see if we modified ld.so.conf.  If we did, then we need
	  # to properly restore it.
	  #
	  if (defined db_get_answer_if_exists('LD_DOT_SO_DOT_CONF_MODIFIED')) {
	    my $file = db_get_answer('LD_DOT_SO_DOT_CONF_MODIFIED');
	    block_restore($file, $cMarkerBegin, $cMarkerEnd);
	  }

	  if (internal_which('ldconfig') ne '') {
	    system('ldconfig &> /dev/null');
	  }
	}

	# Call the prelink_restore function to fix that if it has been modified.
	prelink_restore();
      }

      # remove the modules added to the list for the initrd.
      # Also restore the system Ramdisk (either initrd or initramfs)
      restore_appended_files();
      restore_backedup_files(\%fileToRestore);
      deconfigure_initmodfile();
      restore_kernel_initrd();

      if (defined db_get_answer_if_exists('VMWGFX_CONFED') &&
	  db_get_answer('VMWGFX_CONFED') eq 'yes' &&
	  (internal_which('ldconfig') ne '')) {
	  system('ldconfig &> /dev/null');
      }

      deconfigure_updatedb();
      unset_kmod_db_entries();

      # Check the DB to see if we need to restart HAL.
      if (defined db_get_answer_if_exists('HAL_RESTART_ON_UNINSTALL') and
         db_get_answer('HAL_RESTART_ON_UNINSTALL') eq 'yes') {
         restart_hal();
      }

      # do not kill vmtoolsd on upgrade (see bug #838010)
      if (!defined($gOption{'upgrade'}) || $gOption{'upgrade'} == 0) {
        # Kill vmusr vmtoolsd instance before we exit.
        my $pkillBin = internal_which('pkill');
        if (-x $pkillBin) {
          system("$pkillBin -f 'vmtoolsd -n vmusr' >/dev/null 2>&1");
        }
      }

    } elsif (vmware_product() eq 'vix') {
      uninstall_vix();
    } elsif (vmware_product() eq 'ws') {
      uninstall('/vmware');
    } elsif (vmware_product() eq 'vix-disklib') {
      uninstall('/vmware-vix-disklib');
    } elsif (vmware_product() eq 'nvdk') {
      uninstall('/nvdk');
    } else {
         uninstall('/vmware');
    }

    db_save();
    if (vmware_product() eq 'acevm') {
      print wrap("The removal of VMware ACE $gManifest{'acename'}" .
                 " completed successfully.\n\n", 0);
    } else {
       my $msg = 'The removal of ' . vmware_longname() . ' completed '
                 . 'successfully.';
       if (!defined($gOption{'upgrade'}) || $gOption{'upgrade'} == 0) {
          $msg .= "  Thank you for having tried this software.";
       }
       $msg .= "\n\n";
       print wrap($msg, 0);
    }

    exit 0;
  }

  error('This program must be named ' . $cInstallerFileName . ' or '
        . $gUninstallerFileName . '.' . "\n\n");
}

main();
