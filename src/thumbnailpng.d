// What is this module called?
module thumbnailpng;

// What does this module require to function?
import std.algorithm.sorting : sort;
import std.array;
import std.bitmanip;
import std.conv;
import std.digest.crc;
import std.digest.md;
import std.format;
import std.string;

// Helpers for freedesktop thumbnails (https://specifications.freedesktop.org/thumbnail-spec/latest/).
// Kept free of other application modules so they can be unit tested on their own.

// file:// URI of an absolute local path, escaped exactly as GIO does (g_file_get_uri):
// ASCII letters, digits, '/' and "!$&'()*+,-.:=@_~" are kept, every other byte is %XX (upper case)
string fileUriForPath(string absolutePath) {
	auto result = appender!string();
	result.put("file://");
	foreach (ubyte b; cast(const(ubyte)[]) absolutePath) {
		if (((b >= 'a') && (b <= 'z')) || ((b >= 'A') && (b <= 'Z')) || ((b >= '0') && (b <= '9')) ||
			(b == '/') || (indexOf("!$&'()*+,-.:=@_~", cast(char) b) >= 0)) {
			result.put(cast(char) b);
		} else {
			result.put(format("%%%02X", b));
		}
	}
	return result.data;
}

// Thumbnail file name for a URI: md5 of the exact URI string, lower-case hex, ".png"
string thumbnailFileName(string uri) {
	return toLower(toHexString(md5Of(uri)).idup) ~ ".png";
}

private immutable ubyte[8] pngSignature = [0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'];

// One PNG chunk: type and data
struct PngChunk {
	string type;
	const(ubyte)[] data;
}

// Split a PNG into chunks. Returns false if it is not a well-formed PNG.
bool parsePngChunks(const(ubyte)[] png, out PngChunk[] chunks) {
	if ((png.length < pngSignature.length) || (png[0 .. pngSignature.length] != pngSignature[])) return false;
	size_t offset = pngSignature.length;
	while (offset < png.length) {
		if (offset + 12 > png.length) return false;
		uint length = bigEndianToNative!uint(png[offset .. offset + 4][0 .. 4]);
		if (offset + 12 + length > png.length) return false;
		string type = cast(string) png[offset + 4 .. offset + 8].idup;
		const(ubyte)[] data = png[offset + 8 .. offset + 8 + length];
		uint storedCrc = bigEndianToNative!uint(png[offset + 8 + length .. offset + 12 + length][0 .. 4]);
		if (storedCrc != pngChunkCrc(type, data)) return false;
		chunks ~= PngChunk(type, data);
		offset += 12 + length;
		if (type == "IEND") return offset == png.length;
	}
	return false;
}

// CRC32 of a chunk's type and data, as stored (big-endian) in the PNG
uint pngChunkCrc(string type, const(ubyte)[] data) {
	CRC32 crc;
	crc.put(cast(const(ubyte)[]) type);
	crc.put(data);
	ubyte[4] digest = crc.finish();
	// std.digest.crc returns the CRC value in little-endian byte order
	return littleEndianToNative!uint(digest);
}

// Serialise one chunk: length, type, data, CRC32
ubyte[] encodePngChunk(string type, const(ubyte)[] data) {
	ubyte[] result;
	result ~= nativeToBigEndian(cast(uint) data.length)[];
	result ~= cast(const(ubyte)[]) type;
	result ~= data;
	result ~= nativeToBigEndian(pngChunkCrc(type, data))[];
	return result;
}

// Value of a tEXt chunk with this keyword, or null
string pngTextValue(const(PngChunk)[] chunks, string keyword) {
	foreach (chunk; chunks) {
		if (chunk.type != "tEXt") continue;
		auto separator = indexOf(cast(const(char)[]) chunk.data, '\0');
		if (separator < 0) continue;
		if (cast(const(char)[]) chunk.data[0 .. separator] == keyword) {
			return cast(string) chunk.data[separator + 1 .. $].idup;
		}
	}
	return null;
}

// Return 'png' with every "Thumb::*" tEXt chunk replaced by the given ones, inserted before IEND.
// Returns null if 'png' is not a well-formed PNG.
ubyte[] withThumbnailTextChunks(const(ubyte)[] png, string[string] thumbText) {
	PngChunk[] chunks;
	if (!parsePngChunks(png, chunks)) return null;
	ubyte[] result = pngSignature.dup;
	foreach (chunk; chunks) {
		if (chunk.type == "tEXt") {
			auto separator = indexOf(cast(const(char)[]) chunk.data, '\0');
			if ((separator >= 0) && startsWith(cast(const(char)[]) chunk.data[0 .. separator], "Thumb::")) continue;
		}
		if (chunk.type == "IEND") {
			foreach (keyword; thumbText.keys.sort) {
				ubyte[] data = cast(ubyte[]) (keyword ~ "\0" ~ thumbText[keyword]).dup;
				result ~= encodePngChunk("tEXt", data);
			}
		}
		result ~= encodePngChunk(chunk.type, chunk.data);
	}
	return result;
}

unittest {
	// GIO escaping (compare: python3 Gio.File.new_for_path(p).get_uri())
	assert(fileUriForPath("/tmp/a b/å.jpg") == "file:///tmp/a%20b/%C3%A5.jpg");
	assert(fileUriForPath("/x/ !\"#$%&'()*+,-.:;<=>?@[\\]^_`{|}~") == "file:///x/%20!%22%23$%25&'()*+,-.:%3B%3C=%3E%3F@%5B%5C%5D%5E_%60%7B%7C%7D~");
	// md5 naming (compare: hashlib.md5(uri.encode()).hexdigest())
	assert(thumbnailFileName("file:///tmp/a%20b/%C3%A5.jpg").length == 36);
	// CRC of an empty IEND chunk is the well-known AE426082
	assert(pngChunkCrc("IEND", []) == 0xAE426082);
}
