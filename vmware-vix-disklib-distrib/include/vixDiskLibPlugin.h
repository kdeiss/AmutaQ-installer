/* **************************************************************************
 * Copyright 2008 VMware, Inc.  All rights reserved. -- VMware Confidential
 *
 * vixDiskLibPlugin.h --
 * 
 * Interface for DiskLib libraries, implemented as collections of one or more
 * plugins into DiskLib. 
 *
 * *****************************************************************************/

#ifndef __VIXDISKLIBPLUGIN__
#define __VIXDISKLIBPLUGIN__

#include "vixDiskLib.h"

#if defined(__cplusplus)
extern "C" {
#endif

/*
 * Current major and minor version of the DiskLib Plugin interface as 
 * described by this header file.
 */
#define VIXDISKLIB_PLUGIN_MAJOR_VERSION 1
#define VIXDISKLIB_PLUGIN_MINOR_VERSION 0

typedef enum {
   VIXDISKLIB_PLUGIN_TYPE_TRANSPORT,
   VIXDISKLIB_PLUGIN_TYPE_NAS,
   VIXDISKLIB_PLUGIN_TYPE_TRANSPORT_NO_UNLOAD,
} VixDiskLibPluginType;

/**
 * Prototype for initializing a plugin in the library. This
 * function will be called when the plugin is loaded to initializze
 * the plugin. If anything but VIX_OK is returned, the plugin will not
 * be loaded.
 *
 * @param log IN Log function.
 * @param log IN Warning function.
 * @param log IN Panic function.
 */
typedef VixError
(VixDiskLibPluginInit)(VixDiskLibGenericLogFunc *log,
                       VixDiskLibGenericLogFunc *warn,
                       VixDiskLibGenericLogFunc *panic);
   
/**
 * Function to be called when a plugin is unloaded.
 */
typedef void
(VixDiskLibPluginDone)(void);


/**
 * Plugin function table to be exported for each plugin the
 * plugin library contains.  See the description of the various data types for
 * explanation.
 */
typedef struct {
   int majorVersion; /** Major version supported by this plugin. */
   int minorVersion; /** Minor version supported by this plugin. */
   VixDiskLibPluginType type; /** The type of plugin this is */
   const char *name; /** Name associated with this plugin. */
   VixDiskLibPluginInit     *Init; /** Optional */
   VixDiskLibPluginDone     *Done; /** Optional */
} VixDiskLibPlugin;

/**
 * Main entry point into plugin that must be exported. This is an array
 * of pointers to ViDiskLibPlugin structures corresponding to the plugins
 * in this library. The last element in the array must be a NULL pointer.
 */
extern VixDiskLibPlugin **VixDiskLibPlugin_EntryPoint;

#if defined(__cplusplus)
}
#endif

#endif

