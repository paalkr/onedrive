// What is this module called?
module ondemandglue;

// What does this module require to function?
import std.concurrency;

// What other modules that we have created do we need to import?
import hydration;
import itemdb;
import log;

// Start the on-demand FUSE mount of 'mountPoint', serving 'backingDir'.
// Returns false if the mount could not be started.
//
// Stub for the engine branch: the real implementation constructs OnDemandFs from
// src/ondemand.d (vfs stream) and starts the background mount loop. It is replaced
// at merge time.
bool startOnDemandMount(ItemDatabase itemDB, HydrationService hydrationService, OnDemandChangeQueue changeQueue, Tid mainTid, string mountPoint, string backingDir, string rootDriveId, string rootId) {
	addLogEntry("ERROR: on-demand mount not built in");
	return false;
}

// Stop the on-demand FUSE mount (fuse_exit + fuse_unmount, then join). Safe to call when not mounted.
void stopOnDemandMount() {
}
