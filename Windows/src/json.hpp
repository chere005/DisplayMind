#pragma once
#include <string>
#include <vector>
#include <map>
#include <variant>
#include <stdexcept>
#include <charconv>
#include <cmath>
#include <limits>

namespace dm {
// Small, strict UTF-8 JSON codec. Duplicate keys, fractional integers and malformed
// Unicode are errors: a damaged settings file must never silently change meaning.
class Json {
public:
	using Array = std::vector<Json>;
	using Object = std::map<std::string, Json>;
	using Value = std::variant<std::nullptr_t, bool, int64_t, std::string, Array, Object>;
	Value value = nullptr;
	Json() = default;
	Json(std::nullptr_t) {}
	Json(bool v) : value(v) {}
	Json(int v) : value(int64_t(v)) {}
	Json(unsigned v) : value(int64_t(v)) {}
	Json(int64_t v) : value(v) {}
	Json(const char* v) : value(std::string(v)) {}
	Json(std::string v) : value(std::move(v)) {}
	Json(Array v) : value(std::move(v)) {}
	Json(Object v) : value(std::move(v)) {}
	bool null() const { return std::holds_alternative<std::nullptr_t>(value); }
	const Object& object() const { return get<Object>(); }
	const Array& array() const { return get<Array>(); }
	const std::string& string() const { return get<std::string>(); }
	bool boolean() const { return get<bool>(); }
	int64_t integer() const { return get<int64_t>(); }
	int number() const {
		auto n = integer();
		if (n < INT_MIN || n > INT_MAX) throw std::runtime_error("JSON integer out of range");
		return static_cast<int>(n);
	}
	bool has(const std::string& k) const { return object().count(k) != 0; }
	const Json& at(const std::string& k) const {
		auto i = object().find(k);
		if (i == object().end()) throw std::runtime_error("Missing JSON field: " + k);
		return i->second;
	}
	std::string str(const std::string& k, std::string fallback = {}) const { return has(k) ? at(k).string() : fallback; }
	bool flag(const std::string& k, bool fallback = false) const { return has(k) ? at(k).boolean() : fallback; }
	int num(const std::string& k, int fallback = 0) const { return has(k) ? at(k).number() : fallback; }
	std::string dump(int level = 0) const {
		if (null()) return "null";
		if (auto b = std::get_if<bool>(&value)) return *b ? "true" : "false";
		if (auto n = std::get_if<int64_t>(&value)) return std::to_string(*n);
		if (auto s = std::get_if<std::string>(&value)) return quote(*s);
		std::string out;
		if (auto a = std::get_if<Array>(&value)) {
			out = "[";
			for (size_t i = 0; i < a->size(); ++i) { if (i) out += ","; out += "\n" + std::string(level + 1, '\t') + (*a)[i].dump(level + 1); }
			return out + (a->empty() ? "" : "\n" + std::string(level, '\t')) + "]";
		}
		out = "{";
		for (const auto& [k, v] : object()) { if (out.size() > 1) out += ","; out += "\n" + std::string(level + 1, '\t') + quote(k) + ": " + v.dump(level + 1); }
		return out + (object().empty() ? "" : "\n" + std::string(level, '\t')) + "}";
	}
	static Json parse(const std::string& text) {
		if (text.size() > 8 * 1024 * 1024) throw std::runtime_error("JSON file exceeds 8 MiB");
		Parser p{text}; auto result = p.read(0); p.space();
		if (p.pos != text.size()) p.fail();
		return result;
	}
	bool operator==(const Json&) const = default;
private:
	template<class T> const T& get() const {
		auto p = std::get_if<T>(&value); if (!p) throw std::runtime_error("Wrong JSON field type"); return *p;
	}
	static std::string quote(const std::string& s) {
		std::string o = "\"";
		for (unsigned char c : s) {
			if (c == '"' || c == '\\') { o += '\\'; o += char(c); }
			else if (c < 32) { const char* h = "0123456789abcdef"; o += "\\u00"; o += h[c >> 4]; o += h[c & 15]; }
			else o += char(c);
		}
		return o + '"';
	}
	struct Parser {
		const std::string& s;
		size_t pos = 0;
		[[noreturn]] void fail() const { throw std::runtime_error("Invalid JSON at byte " + std::to_string(pos)); }
		void space() { while (pos < s.size() && (s[pos] == ' ' || s[pos] == '\r' || s[pos] == '\n' || s[pos] == '\t')) ++pos; }
		bool take(char c) { space(); if (pos < s.size() && s[pos] == c) { ++pos; return true; } return false; }
		unsigned hex4() {
			unsigned n = 0;
			for (int i = 0; i < 4; ++i) {
				if (pos >= s.size()) fail(); char c = s[pos++]; n <<= 4;
				if (c >= '0' && c <= '9') n |= c - '0'; else if (c >= 'a' && c <= 'f') n |= c - 'a' + 10; else if (c >= 'A' && c <= 'F') n |= c - 'A' + 10; else fail();
			}
			return n;
		}
		void utf8(std::string& o, unsigned c) {
			if (c < 128) o += char(c);
			else if (c < 2048) { o += char(192 | (c >> 6)); o += char(128 | (c & 63)); }
			else if (c < 65536) { o += char(224 | (c >> 12)); o += char(128 | ((c >> 6) & 63)); o += char(128 | (c & 63)); }
			else { o += char(240 | (c >> 18)); o += char(128 | ((c >> 12) & 63)); o += char(128 | ((c >> 6) & 63)); o += char(128 | (c & 63)); }
		}
		std::string string() {
			if (!take('"')) fail(); std::string o;
			while (pos < s.size()) {
				unsigned char c = s[pos++];
				if (c == '"') return o;
				if (c < 32) fail();
				if (c == '\\') {
					if (pos >= s.size()) fail(); char e = s[pos++];
					if (e == '"' || e == '\\' || e == '/') o += e;
					else if (e == 'b') o += '\b'; else if (e == 'f') o += '\f'; else if (e == 'n') o += '\n'; else if (e == 'r') o += '\r'; else if (e == 't') o += '\t';
					else if (e == 'u') {
						unsigned n = hex4();
						if (n >= 0xd800 && n <= 0xdbff) {
							if (pos + 2 > s.size() || s[pos++] != '\\' || s[pos++] != 'u') fail();
							unsigned lo = hex4(); if (lo < 0xdc00 || lo > 0xdfff) fail(); n = 65536 + ((n - 0xd800) << 10) + lo - 0xdc00;
						} else if (n >= 0xdc00 && n <= 0xdfff) fail();
						utf8(o, n);
					} else fail();
				} else if (c < 128) o += char(c);
				else {
					unsigned n = 0, count = 0, minimum = 0;
					if (c >= 0xc2 && c <= 0xdf) { n = c & 31; count = 1; minimum = 128; }
					else if (c >= 0xe0 && c <= 0xef) { n = c & 15; count = 2; minimum = 2048; }
					else if (c >= 0xf0 && c <= 0xf4) { n = c & 7; count = 3; minimum = 65536; } else fail();
					for (unsigned i = 0; i < count; ++i) { if (pos >= s.size()) fail(); auto b = static_cast<unsigned char>(s[pos++]); if ((b & 192) != 128) fail(); n = (n << 6) | (b & 63); }
					if (n < minimum || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) fail(); utf8(o, n);
				}
			} fail();
		}
		Json read(int depth) {
			if (depth > 64) fail(); space(); if (pos >= s.size()) fail();
			if (s[pos] == '"') return string();
			if (take('{')) { Object o; if (take('}')) return o; do { auto k = string(); if (!take(':')) fail(); if (!o.emplace(k, read(depth + 1)).second) fail(); } while (take(',')); if (!take('}')) fail(); return o; }
			if (take('[')) { Array a; if (take(']')) return a; do { a.push_back(read(depth + 1)); if (a.size() > 100000) fail(); } while (take(',')); if (!take(']')) fail(); return a; }
			for (auto token : {"true", "false", "null"}) { size_t n = std::char_traits<char>::length(token); if (s.compare(pos, n, token) == 0) { pos += n; return token[0] == 'n' ? Json() : Json(token[0] == 't'); } }
			size_t start = pos; if (s[pos] == '-') ++pos;
			if (pos >= s.size() || s[pos] < '0' || s[pos] > '9') fail();
			if (s[pos] == '0') ++pos; else while (pos < s.size() && s[pos] >= '0' && s[pos] <= '9') ++pos;
			int64_t n = 0; auto result = std::from_chars(s.data() + start, s.data() + pos, n);
			if (result.ec != std::errc() || result.ptr != s.data() + pos) fail(); return n;
		}
	};
};
}
