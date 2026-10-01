// What is this module called?
module dbusstatus;

// What does this module require to function?
import core.atomic;
import core.sync.mutex;
import core.thread;
import core.time;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.path;
import std.string;

// What other modules that we have created do we need to import?
import log;

// D-Bus status interface (session bus): io.github.abraunegg.OneDrive1 on /io/github/abraunegg/OneDrive,
// bus name io.github.abraunegg.OneDrive.i<first 16 hex of sha256(confdir)>.
//
// The engine publishes state through the status* functions below: they only update an in-memory
// snapshot under a short lock and never wait for D-Bus. A dedicated thread with its own private
// session connection serves the snapshot and emits the signals.

enum string statusObjectPath = "/io/github/abraunegg/OneDrive";
enum string statusInterface = "io.github.abraunegg.OneDrive1";
enum string statusBusNamePrefix = "io.github.abraunegg.OneDrive.i";

// Bus name of the instance using this configuration directory
string statusBusName(string configDir) {
	string digest = toLower(toHexString(sha256Of(buildNormalizedPath(absolutePath(configDir)))).idup);
	return statusBusNamePrefix ~ digest[0 .. 16];
}

// ------------------------------------------------------------------------------------------------
// Published state (engine side)
// ------------------------------------------------------------------------------------------------

private struct TransferEntry {
	string path;
	string direction;
	string state;
	ulong bytesDone;
	ulong bytesTotal;
	MonoTime lastProgress;
}

private struct IssueEntry {
	string issueId;
	string path;
	string kind;
	string severity;
	string message;
	long unixTime;
}

private __gshared Mutex statusMutex;
private __gshared bool statusEnabled = false;
// Immutable after statusConfigure()
private __gshared string statusVersion;
private __gshared string statusConfigDir;
private __gshared string statusSyncDir;
private __gshared bool statusOnDemand;
private __gshared string[] statusCapabilities;
// Mutable, guarded by statusMutex
private __gshared string statusAccount;
private __gshared string statusAccountType = "unknown";
private __gshared string statusState = "starting";
private __gshared string statusStateDetail = "Starting";
private __gshared long statusLastSyncTime = 0;
private __gshared ulong statusQuotaUsed = 0;
private __gshared ulong statusQuotaTotal = 0;
private __gshared uint statusPendingUploads = 0;
private __gshared uint statusPendingDownloads = 0;
private __gshared TransferEntry[string] statusTransfers;
private __gshared IssueEntry[] statusIssues;
private __gshared ulong statusIssueCounter = 0;
private __gshared bool[string] statusChangedProperties;
private __gshared bool statusTransfersChanged = false;
private __gshared bool statusIssuesChanged = false;
private shared bool statusSyncNowRequested = false;

private enum size_t maxIssues = 500;

shared static this() {
	statusMutex = new Mutex();
}

// Enable publishing and set the immutable properties. Called once, before the service starts.
void statusConfigure(string clientVersion, string configDir, string syncDir, bool onDemand) {
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	statusVersion = clientVersion;
	statusConfigDir = buildNormalizedPath(absolutePath(configDir));
	statusSyncDir = buildNormalizedPath(absolutePath(syncDir));
	statusOnDemand = onDemand;
	statusCapabilities = onDemand ? ["ondemand", "actions", "issues", "transfers"] : ["issues", "transfers"];
	statusEnabled = true;
}

private void markChangedLocked(string property) {
	statusChangedProperties[property] = true;
}

void statusSetState(string state, string detail) {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	if (statusState != state) {
		statusState = state;
		markChangedLocked("State");
	}
	if (statusStateDetail != detail) {
		statusStateDetail = detail;
		markChangedLocked("StateDetail");
	}
}

string statusCurrentState() {
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	return statusState;
}

void statusSetAccount(string account, string accountType) {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	string type = canFind(["personal", "business", "sharepoint"], accountType) ? accountType : ((accountType == "documentLibrary") ? "sharepoint" : "unknown");
	if (statusAccount != account) {
		statusAccount = account;
		markChangedLocked("Account");
	}
	if (statusAccountType != type) {
		statusAccountType = type;
		markChangedLocked("AccountType");
	}
}

void statusSetQuota(ulong used, ulong total) {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	if (statusQuotaUsed != used) {
		statusQuotaUsed = used;
		markChangedLocked("QuotaUsed");
	}
	if (statusQuotaTotal != total) {
		statusQuotaTotal = total;
		markChangedLocked("QuotaTotal");
	}
}

void statusSetPendingUploads(size_t count) {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	uint value = cast(uint) min(count, uint.max);
	if (statusPendingUploads != value) {
		statusPendingUploads = value;
		markChangedLocked("PendingUploads");
	}
}

void statusSetPendingDownloads(size_t count) {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	uint value = cast(uint) min(count, uint.max);
	if (statusPendingDownloads != value) {
		statusPendingDownloads = value;
		markChangedLocked("PendingDownloads");
	}
}

void statusSyncCompleted() {
	if (!statusEnabled) return;
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	statusLastSyncTime = Clock.currTime(UTC()).toUnixTime();
	markChangedLocked("LastSyncTime");
}

private string statusRelativePath(string path) {
	string normalised = buildNormalizedPath(path);
	if (isAbsolute(normalised)) {
		normalised = relativePath(normalised, statusSyncDir);
	}
	if (startsWith(normalised, "./")) normalised = normalised[2 .. $];
	return normalised;
}

// A transfer started (direction: upload | download | hydrate). 'path' is relative to the sync directory.
void statusTransferBegin(string path, string direction, ulong bytesTotal) {
	if (!statusEnabled) return;
	string relative = statusRelativePath(path);
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	statusTransfers[direction ~ ":" ~ relative] = TransferEntry(relative, direction, "active", 0, bytesTotal, MonoTime.zero);
	statusTransfersChanged = true;
}

void statusTransferProgress(string path, string direction, ulong bytesDone) {
	if (!statusEnabled) return;
	string relative = statusRelativePath(path);
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	if (auto entry = (direction ~ ":" ~ relative) in statusTransfers) {
		// Progress callbacks are frequent; record at most four updates per second per transfer
		MonoTime now = MonoTime.currTime;
		if ((now - entry.lastProgress) < dur!"msecs"(250)) return;
		entry.lastProgress = now;
		entry.bytesDone = bytesDone;
		statusTransfersChanged = true;
	}
}

void statusTransferEnd(string path, string direction) {
	if (!statusEnabled) return;
	string relative = statusRelativePath(path);
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	if ((direction ~ ":" ~ relative) in statusTransfers) {
		statusTransfers.remove(direction ~ ":" ~ relative);
		statusTransfersChanged = true;
	}
}

// Record an issue. An issue of the same kind for the same path replaces the earlier one.
void statusAddIssue(string path, string kind, string severity, string message) {
	if (!statusEnabled) return;
	string relative = path.empty ? "" : statusRelativePath(path);
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	long now = Clock.currTime(UTC()).toUnixTime();
	string issueId;
	foreach (index, issue; statusIssues) {
		if ((issue.kind == kind) && (issue.path == relative)) {
			issueId = issue.issueId;
			statusIssues = statusIssues[0 .. index] ~ statusIssues[index + 1 .. $];
			break;
		}
	}
	if (issueId.empty) {
		statusIssueCounter++;
		issueId = format("%x", statusIssueCounter);
	}
	statusIssues ~= IssueEntry(issueId, relative, kind, severity, message, now);
	if (statusIssues.length > maxIssues) statusIssues = statusIssues[$ - maxIssues .. $];
	statusIssuesChanged = true;
}

// Remove the issues of this kind for this path (the condition no longer applies)
void statusClearIssue(string path, string kind) {
	if (!statusEnabled) return;
	string relative = path.empty ? "" : statusRelativePath(path);
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	size_t before = statusIssues.length;
	statusIssues = statusIssues.filter!(issue => !((issue.kind == kind) && (issue.path == relative))).array;
	if (statusIssues.length != before) statusIssuesChanged = true;
}

private bool statusDismissIssue(string issueId) {
	statusMutex.lock();
	scope(exit) statusMutex.unlock();
	size_t before = statusIssues.length;
	statusIssues = statusIssues.filter!(issue => issue.issueId != issueId).array;
	if (statusIssues.length == before) return false;
	statusIssuesChanged = true;
	return true;
}

// Was SyncNow() called since the last call? The monitor loop then starts a sync cycle.
bool consumeStatusSyncNowRequest() {
	return cas(&statusSyncNowRequested, true, false);
}

bool statusSyncNowPending() {
	return atomicLoad(statusSyncNowRequested);
}

// ------------------------------------------------------------------------------------------------
// libdbus binding (only what the service uses)
// ------------------------------------------------------------------------------------------------

private extern(C) {
	alias dbus_bool_t = uint;
	struct DBusError {
		char* name;
		char* message;
		uint[8] dummy;
		void* padding;
	}
	struct DBusConnection;
	struct DBusMessage;
	// libdbus' DBusMessageIter is a plain struct of 14 machine words or less; reserve generously
	struct DBusMessageIter {
		align(8) ubyte[128] storage;
	}

	void dbus_error_init(DBusError* error);
	void dbus_error_free(DBusError* error);
	dbus_bool_t dbus_error_is_set(const(DBusError)* error);
	DBusConnection* dbus_bus_get_private(int type, DBusError* error);
	void dbus_connection_set_exit_on_disconnect(DBusConnection* connection, dbus_bool_t exitOnDisconnect);
	int dbus_bus_request_name(DBusConnection* connection, const(char)* name, uint flags, DBusError* error);
	int dbus_bus_release_name(DBusConnection* connection, const(char)* name, DBusError* error);
	dbus_bool_t dbus_connection_read_write(DBusConnection* connection, int timeoutMilliseconds);
	DBusMessage* dbus_connection_pop_message(DBusConnection* connection);
	dbus_bool_t dbus_connection_send(DBusConnection* connection, DBusMessage* message, uint* serial);
	void dbus_connection_flush(DBusConnection* connection);
	void dbus_connection_close(DBusConnection* connection);
	void dbus_connection_unref(DBusConnection* connection);
	int dbus_message_get_type(DBusMessage* message);
	const(char)* dbus_message_get_interface(DBusMessage* message);
	const(char)* dbus_message_get_member(DBusMessage* message);
	const(char)* dbus_message_get_path(DBusMessage* message);
	dbus_bool_t dbus_message_get_no_reply(DBusMessage* message);
	DBusMessage* dbus_message_new_method_return(DBusMessage* methodCall);
	DBusMessage* dbus_message_new_error(DBusMessage* replyTo, const(char)* errorName, const(char)* errorMessage);
	DBusMessage* dbus_message_new_signal(const(char)* path, const(char)* iface, const(char)* name);
	void dbus_message_unref(DBusMessage* message);
	dbus_bool_t dbus_message_iter_init(DBusMessage* message, DBusMessageIter* iter);
	dbus_bool_t dbus_message_iter_next(DBusMessageIter* iter);
	int dbus_message_iter_get_arg_type(DBusMessageIter* iter);
	void dbus_message_iter_get_basic(DBusMessageIter* iter, void* value);
	// Declared with an int result to match src/intune.d's declaration of the same C symbol (the result is unused)
	dbus_bool_t dbus_message_iter_init_append(DBusMessage* message, DBusMessageIter* iter);
	dbus_bool_t dbus_message_iter_append_basic(DBusMessageIter* iter, int type, const(void)* value);
	dbus_bool_t dbus_message_iter_open_container(DBusMessageIter* iter, int type, const(char)* containedSignature, DBusMessageIter* sub);
	dbus_bool_t dbus_message_iter_close_container(DBusMessageIter* iter, DBusMessageIter* sub);
}

private enum int DBUS_BUS_SESSION = 0;
private enum uint DBUS_NAME_FLAG_DO_NOT_QUEUE = 4;
private enum int DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER = 1;
private enum int DBUS_MESSAGE_TYPE_METHOD_CALL = 1;
private enum int DBUS_TYPE_STRING = 's';
private enum int DBUS_TYPE_BOOLEAN = 'b';
private enum int DBUS_TYPE_UINT32 = 'u';
private enum int DBUS_TYPE_INT64 = 'x';
private enum int DBUS_TYPE_UINT64 = 't';
private enum int DBUS_TYPE_ARRAY = 'a';
private enum int DBUS_TYPE_VARIANT = 'v';
private enum int DBUS_TYPE_STRUCT = 'r';
private enum int DBUS_TYPE_DICT_ENTRY = 'e';

// Marshalling helpers. Strings are copied to NUL-terminated buffers that live until the message is sent.
private void appendString(DBusMessageIter* iter, string value) {
	const(char)* pointer = toStringz(value);
	dbus_message_iter_append_basic(iter, DBUS_TYPE_STRING, &pointer);
}

private void appendBool(DBusMessageIter* iter, bool value) {
	dbus_bool_t raw = value ? 1 : 0;
	dbus_message_iter_append_basic(iter, DBUS_TYPE_BOOLEAN, &raw);
}

private void appendUint(DBusMessageIter* iter, uint value) {
	dbus_message_iter_append_basic(iter, DBUS_TYPE_UINT32, &value);
}

private void appendInt64(DBusMessageIter* iter, long value) {
	dbus_message_iter_append_basic(iter, DBUS_TYPE_INT64, &value);
}

private void appendUint64(DBusMessageIter* iter, ulong value) {
	dbus_message_iter_append_basic(iter, DBUS_TYPE_UINT64, &value);
}

private void appendStringArray(DBusMessageIter* iter, string[] values) {
	DBusMessageIter array;
	dbus_message_iter_open_container(iter, DBUS_TYPE_ARRAY, "s", &array);
	foreach (value; values) appendString(&array, value);
	dbus_message_iter_close_container(iter, &array);
}

// ------------------------------------------------------------------------------------------------
// Service thread
// ------------------------------------------------------------------------------------------------

private immutable string[] propertyNames = [
	"Version", "ConfigDir", "SyncDir", "Account", "AccountType", "OnDemand", "Capabilities",
	"State", "StateDetail", "LastSyncTime", "QuotaUsed", "QuotaTotal", "PendingUploads", "PendingDownloads"
];

private enum string introspectionXml = `<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="io.github.abraunegg.OneDrive1">
    <property name="Version" type="s" access="read"/>
    <property name="ConfigDir" type="s" access="read"/>
    <property name="SyncDir" type="s" access="read"/>
    <property name="Account" type="s" access="read"/>
    <property name="AccountType" type="s" access="read"/>
    <property name="OnDemand" type="b" access="read"/>
    <property name="Capabilities" type="as" access="read"/>
    <property name="State" type="s" access="read"/>
    <property name="StateDetail" type="s" access="read"/>
    <property name="LastSyncTime" type="x" access="read"/>
    <property name="QuotaUsed" type="t" access="read"/>
    <property name="QuotaTotal" type="t" access="read"/>
    <property name="PendingUploads" type="u" access="read"/>
    <property name="PendingDownloads" type="u" access="read"/>
    <method name="GetTransfers">
      <arg name="transfers" type="a(ssstt)" direction="out"/>
    </method>
    <method name="GetIssues">
      <arg name="issues" type="a(sssssx)" direction="out"/>
    </method>
    <method name="DismissIssue">
      <arg name="issueId" type="s" direction="in"/>
    </method>
    <method name="SyncNow"/>
    <method name="Pause">
      <arg name="minutes" type="u" direction="in"/>
    </method>
    <method name="Resume"/>
    <signal name="IssuesChanged"/>
    <signal name="TransfersChanged"/>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg name="interface_name" type="s" direction="in"/>
      <arg name="property_name" type="s" direction="in"/>
      <arg name="value" type="v" direction="out"/>
    </method>
    <method name="GetAll">
      <arg name="interface_name" type="s" direction="in"/>
      <arg name="properties" type="a{sv}" direction="out"/>
    </method>
    <method name="Set">
      <arg name="interface_name" type="s" direction="in"/>
      <arg name="property_name" type="s" direction="in"/>
      <arg name="value" type="v" direction="in"/>
    </method>
    <signal name="PropertiesChanged">
      <arg name="interface_name" type="s"/>
      <arg name="changed_properties" type="a{sv}"/>
      <arg name="invalidated_properties" type="as"/>
    </signal>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect">
      <arg name="xml_data" type="s" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId">
      <arg name="machine_uuid" type="s" direction="out"/>
    </method>
  </interface>
</node>
`;

final class DBusStatusService {
	private Thread worker;
	private shared bool stopRequested = false;
	private shared bool running = false;
	private string busName;

	this(string configDir) {
		busName = statusBusName(configDir);
	}

	string name() {
		return busName;
	}

	void start() {
		worker = new Thread(&serve);
		worker.isDaemon = true;
		worker.start();
	}

	// Release the bus name and stop the thread (bounded wait)
	void stop() {
		atomicStore(stopRequested, true);
		if (worker is null) return;
		MonoTime deadline = MonoTime.currTime + dur!"seconds"(5);
		while (atomicLoad(running) && (MonoTime.currTime < deadline)) {
			Thread.sleep(dur!"msecs"(50));
		}
		if (!atomicLoad(running)) worker.join(false);
		worker = null;
	}

	private void serve() {
		atomicStore(running, true);
		scope(exit) atomicStore(running, false);

		DBusError error;
		dbus_error_init(&error);
		DBusConnection* connection = dbus_bus_get_private(DBUS_BUS_SESSION, &error);
		if (dbus_error_is_set(&error) || (connection is null)) {
			addLogEntry("D-Bus status interface is not available (no session bus): " ~ (error.message is null ? "unknown error" : to!string(fromStringz(error.message))));
			dbus_error_free(&error);
			return;
		}
		dbus_connection_set_exit_on_disconnect(connection, 0);
		scope(exit) {
			dbus_connection_close(connection);
			dbus_connection_unref(connection);
		}

		int reply = dbus_bus_request_name(connection, toStringz(busName), DBUS_NAME_FLAG_DO_NOT_QUEUE, &error);
		if (dbus_error_is_set(&error) || (reply != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER)) {
			addLogEntry("D-Bus status interface is disabled: the bus name " ~ busName ~ " is already in use (another client instance with the same configuration directory?)");
			dbus_error_free(&error);
			return;
		}
		addLogEntry("D-Bus status interface is available as " ~ busName);

		MonoTime lastPropertiesSignal = MonoTime.zero;
		MonoTime lastTransfersSignal = MonoTime.zero;
		MonoTime lastIssuesSignal = MonoTime.zero;
		immutable Duration signalInterval = dur!"msecs"(500);

		while (!atomicLoad(stopRequested)) {
			// Wait up to 200 ms for incoming messages, then serve all of them
			if (!dbus_connection_read_write(connection, 200)) {
				addLogEntry("D-Bus status interface: the session bus connection was closed");
				break;
			}
			DBusMessage* message;
			while ((message = dbus_connection_pop_message(connection)) !is null) {
				try {
					handleMessage(connection, message);
				} catch (Exception e) {
					addLogEntry("D-Bus status interface: error handling a request: " ~ e.msg);
				}
				dbus_message_unref(message);
			}

			// Signals, each at most twice per second
			MonoTime now = MonoTime.currTime;
			if (now - lastPropertiesSignal >= signalInterval) {
				if (emitPropertiesChanged(connection)) lastPropertiesSignal = now;
			}
			if (now - lastTransfersSignal >= signalInterval) {
				if (takeFlag(statusTransfersChanged)) {
					emitSignal(connection, "TransfersChanged");
					lastTransfersSignal = now;
				}
			}
			if (now - lastIssuesSignal >= signalInterval) {
				if (takeFlag(statusIssuesChanged)) {
					emitSignal(connection, "IssuesChanged");
					lastIssuesSignal = now;
				}
			}
		}

		// Announce the final state, then give up the name
		emitPropertiesChanged(connection);
		dbus_bus_release_name(connection, toStringz(busName), &error);
		if (dbus_error_is_set(&error)) dbus_error_free(&error);
		dbus_connection_flush(connection);
	}

	private static bool takeFlag(ref bool flag) {
		statusMutex.lock();
		scope(exit) statusMutex.unlock();
		bool value = flag;
		flag = false;
		return value;
	}

	private void handleMessage(DBusConnection* connection, DBusMessage* message) {
		if (dbus_message_get_type(message) != DBUS_MESSAGE_TYPE_METHOD_CALL) return;
		string iface = to!string(fromStringz(dbus_message_get_interface(message)));
		string member = to!string(fromStringz(dbus_message_get_member(message)));
		string path = to!string(fromStringz(dbus_message_get_path(message)));

		if (path != statusObjectPath) {
			if ((iface == "org.freedesktop.DBus.Introspectable") && (member == "Introspect")) {
				// Introspection of the parent nodes, so tools can walk down to the object
				replyString(connection, message, introspectParent(path));
				return;
			}
			replyError(connection, message, "org.freedesktop.DBus.Error.UnknownObject", "No such object: " ~ path);
			return;
		}

		switch (iface ~ "." ~ member) {
			case "org.freedesktop.DBus.Introspectable.Introspect":
				replyString(connection, message, introspectionXml);
				return;
			case "org.freedesktop.DBus.Peer.Ping":
				replyEmpty(connection, message);
				return;
			case "org.freedesktop.DBus.Peer.GetMachineId":
				replyError(connection, message, "org.freedesktop.DBus.Error.NotSupported", "GetMachineId is not supported");
				return;
			case "org.freedesktop.DBus.Properties.Get":
				handleGet(connection, message);
				return;
			case "org.freedesktop.DBus.Properties.GetAll":
				handleGetAll(connection, message);
				return;
			case "org.freedesktop.DBus.Properties.Set":
				replyError(connection, message, "org.freedesktop.DBus.Error.PropertyReadOnly", "All properties are read-only");
				return;
			default:
				break;
		}

		// Methods without an interface name are matched by member name only
		if ((iface == statusInterface) || iface.empty) {
			switch (member) {
				case "GetTransfers":
					replyTransfers(connection, message);
					return;
				case "GetIssues":
					replyIssues(connection, message);
					return;
				case "DismissIssue":
					string issueId;
					if (!readStringArgument(message, 0, issueId)) {
						replyError(connection, message, "org.freedesktop.DBus.Error.InvalidArgs", "DismissIssue expects (s)");
						return;
					}
					if (statusDismissIssue(issueId)) {
						replyEmpty(connection, message);
					} else {
						replyError(connection, message, "org.freedesktop.DBus.Error.InvalidArgs", "No such issue: " ~ issueId);
					}
					return;
				case "SyncNow":
					atomicStore(statusSyncNowRequested, true);
					replyEmpty(connection, message);
					return;
				case "Pause":
				case "Resume":
					replyError(connection, message, "org.freedesktop.DBus.Error.NotSupported", "Pause and Resume are not supported by this client ('pause' is not in Capabilities)");
					return;
				default:
					break;
			}
		}
		replyError(connection, message, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method " ~ iface ~ "." ~ member);
	}

	private static string introspectParent(string path) {
		string child;
		if (path == "/") {
			child = "io";
		} else if (startsWith(statusObjectPath, path ~ "/")) {
			string rest = statusObjectPath[path.length + 1 .. $];
			auto separator = indexOf(rest, '/');
			child = separator < 0 ? rest : rest[0 .. separator];
		}
		string xml = "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n<node>\n";
		if (!child.empty) xml ~= "  <node name=\"" ~ child ~ "\"/>\n";
		return xml ~ "</node>\n";
	}

	private static bool readStringArgument(DBusMessage* message, int index, out string value) {
		DBusMessageIter iter;
		if (!dbus_message_iter_init(message, &iter)) return false;
		foreach (i; 0 .. index) {
			if (!dbus_message_iter_next(&iter)) return false;
		}
		if (dbus_message_iter_get_arg_type(&iter) != DBUS_TYPE_STRING) return false;
		const(char)* raw;
		dbus_message_iter_get_basic(&iter, &raw);
		value = to!string(fromStringz(raw));
		return true;
	}

	private void send(DBusConnection* connection, DBusMessage* message, DBusMessage* reply) {
		if (reply is null) return;
		if (!dbus_message_get_no_reply(message)) dbus_connection_send(connection, reply, null);
		dbus_message_unref(reply);
	}

	private void replyEmpty(DBusConnection* connection, DBusMessage* message) {
		send(connection, message, dbus_message_new_method_return(message));
	}

	private void replyString(DBusConnection* connection, DBusMessage* message, string value) {
		DBusMessage* reply = dbus_message_new_method_return(message);
		DBusMessageIter iter;
		dbus_message_iter_init_append(reply, &iter);
		appendString(&iter, value);
		send(connection, message, reply);
	}

	private void replyError(DBusConnection* connection, DBusMessage* message, string errorName, string errorMessage) {
		send(connection, message, dbus_message_new_error(message, toStringz(errorName), toStringz(errorMessage)));
	}

	private void handleGet(DBusConnection* connection, DBusMessage* message) {
		string iface, property;
		if (!readStringArgument(message, 0, iface) || !readStringArgument(message, 1, property)) {
			replyError(connection, message, "org.freedesktop.DBus.Error.InvalidArgs", "Get expects (ss)");
			return;
		}
		if ((iface != statusInterface) || !canFind(propertyNames, property)) {
			replyError(connection, message, "org.freedesktop.DBus.Error.UnknownProperty", "No such property: " ~ iface ~ "." ~ property);
			return;
		}
		DBusMessage* reply = dbus_message_new_method_return(message);
		DBusMessageIter iter;
		dbus_message_iter_init_append(reply, &iter);
		statusMutex.lock();
		appendPropertyVariant(&iter, property);
		statusMutex.unlock();
		send(connection, message, reply);
	}

	private void handleGetAll(DBusConnection* connection, DBusMessage* message) {
		string iface;
		if (!readStringArgument(message, 0, iface)) {
			replyError(connection, message, "org.freedesktop.DBus.Error.InvalidArgs", "GetAll expects (s)");
			return;
		}
		DBusMessage* reply = dbus_message_new_method_return(message);
		DBusMessageIter iter;
		dbus_message_iter_init_append(reply, &iter);
		DBusMessageIter dict;
		dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
		if (iface == statusInterface) {
			statusMutex.lock();
			foreach (property; propertyNames) appendPropertyEntry(&dict, property);
			statusMutex.unlock();
		}
		dbus_message_iter_close_container(&iter, &dict);
		send(connection, message, reply);
	}

	// Caller holds statusMutex
	private static void appendPropertyEntry(DBusMessageIter* dict, string property) {
		DBusMessageIter entry;
		dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, null, &entry);
		appendString(&entry, property);
		appendPropertyVariant(&entry, property);
		dbus_message_iter_close_container(dict, &entry);
	}

	// Caller holds statusMutex
	private static void appendPropertyVariant(DBusMessageIter* iter, string property) {
		DBusMessageIter variant;
		string signature;
		switch (property) {
			case "OnDemand": signature = "b"; break;
			case "Capabilities": signature = "as"; break;
			case "LastSyncTime": signature = "x"; break;
			case "QuotaUsed", "QuotaTotal": signature = "t"; break;
			case "PendingUploads", "PendingDownloads": signature = "u"; break;
			default: signature = "s"; break;
		}
		dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, toStringz(signature), &variant);
		switch (property) {
			case "Version": appendString(&variant, statusVersion); break;
			case "ConfigDir": appendString(&variant, statusConfigDir); break;
			case "SyncDir": appendString(&variant, statusSyncDir); break;
			case "Account": appendString(&variant, statusAccount); break;
			case "AccountType": appendString(&variant, statusAccountType); break;
			case "OnDemand": appendBool(&variant, statusOnDemand); break;
			case "Capabilities": appendStringArray(&variant, statusCapabilities); break;
			case "State": appendString(&variant, statusState); break;
			case "StateDetail": appendString(&variant, statusStateDetail); break;
			case "LastSyncTime": appendInt64(&variant, statusLastSyncTime); break;
			case "QuotaUsed": appendUint64(&variant, statusQuotaUsed); break;
			case "QuotaTotal": appendUint64(&variant, statusQuotaTotal); break;
			case "PendingUploads": appendUint(&variant, statusPendingUploads); break;
			case "PendingDownloads": appendUint(&variant, statusPendingDownloads); break;
			default: appendString(&variant, ""); break;
		}
		dbus_message_iter_close_container(iter, &variant);
	}

	private void replyTransfers(DBusConnection* connection, DBusMessage* message) {
		TransferEntry[] transfers;
		statusMutex.lock();
		transfers = statusTransfers.values;
		statusMutex.unlock();
		transfers.sort!((a, b) => a.path < b.path);

		DBusMessage* reply = dbus_message_new_method_return(message);
		DBusMessageIter iter, array;
		dbus_message_iter_init_append(reply, &iter);
		dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(ssstt)", &array);
		foreach (transfer; transfers) {
			DBusMessageIter entry;
			dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, null, &entry);
			appendString(&entry, transfer.path);
			appendString(&entry, transfer.direction);
			appendString(&entry, transfer.state);
			appendUint64(&entry, transfer.bytesDone);
			appendUint64(&entry, transfer.bytesTotal);
			dbus_message_iter_close_container(&array, &entry);
		}
		dbus_message_iter_close_container(&iter, &array);
		send(connection, message, reply);
	}

	private void replyIssues(DBusConnection* connection, DBusMessage* message) {
		IssueEntry[] issues;
		statusMutex.lock();
		issues = statusIssues.dup;
		statusMutex.unlock();

		DBusMessage* reply = dbus_message_new_method_return(message);
		DBusMessageIter iter, array;
		dbus_message_iter_init_append(reply, &iter);
		dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(sssssx)", &array);
		foreach (issue; issues) {
			DBusMessageIter entry;
			dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, null, &entry);
			appendString(&entry, issue.issueId);
			appendString(&entry, issue.path);
			appendString(&entry, issue.kind);
			appendString(&entry, issue.severity);
			appendString(&entry, issue.message);
			appendInt64(&entry, issue.unixTime);
			dbus_message_iter_close_container(&array, &entry);
		}
		dbus_message_iter_close_container(&iter, &array);
		send(connection, message, reply);
	}

	private void emitSignal(DBusConnection* connection, string name) {
		DBusMessage* signal = dbus_message_new_signal(statusObjectPath, statusInterface, toStringz(name));
		if (signal is null) return;
		dbus_connection_send(connection, signal, null);
		dbus_message_unref(signal);
	}

	// Returns true if a signal was sent
	private bool emitPropertiesChanged(DBusConnection* connection) {
		statusMutex.lock();
		scope(exit) statusMutex.unlock();
		if (statusChangedProperties.length == 0) return false;
		string[] changed = statusChangedProperties.keys;
		statusChangedProperties = null;

		DBusMessage* signal = dbus_message_new_signal(statusObjectPath, "org.freedesktop.DBus.Properties", "PropertiesChanged");
		if (signal is null) return false;
		DBusMessageIter iter, dict;
		dbus_message_iter_init_append(signal, &iter);
		appendString(&iter, statusInterface);
		dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
		foreach (property; propertyNames) {
			if (canFind(changed, property)) appendPropertyEntry(&dict, property);
		}
		dbus_message_iter_close_container(&iter, &dict);
		appendStringArray(&iter, []);
		dbus_connection_send(connection, signal, null);
		dbus_message_unref(signal);
		return true;
	}
}
