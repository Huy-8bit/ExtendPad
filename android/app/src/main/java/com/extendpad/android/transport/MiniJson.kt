package com.extendpad.android.transport

/**
 * Minimal, dependency-free JSON reader/writer for the small control messages.
 * (org.json is an Android stub in local unit tests; this keeps protocol code JVM-testable.)
 * Numbers parse to Long when integral, otherwise Double.
 */
object MiniJson {
    class ParseException(msg: String) : Exception(msg)

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (!p.eof()) throw ParseException("trailing data at ${p.i}")
        return v
    }

    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?> =
        parse(text) as? Map<String, Any?> ?: throw ParseException("not an object")

    fun stringify(v: Any?): String = StringBuilder().also { write(it, v) }.toString()

    private fun write(sb: StringBuilder, v: Any?) {
        when (v) {
            null -> sb.append("null")
            is String -> quote(sb, v)
            is Boolean -> sb.append(if (v) "true" else "false")
            is Int, is Long, is Short, is Byte -> sb.append(v.toString())
            is Float -> if (v.isFinite()) sb.append(v.toDouble().toString()) else sb.append("null")
            is Double -> if (v.isFinite()) sb.append(v.toString()) else sb.append("null")
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, value) in v) {
                    if (!first) sb.append(',')
                    first = false
                    quote(sb, k.toString()); sb.append(':'); write(sb, value)
                }
                sb.append('}')
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (e in v) { if (!first) sb.append(','); first = false; write(sb, e) }
                sb.append(']')
            }
            else -> quote(sb, v.toString())
        }
    }

    private fun quote(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c < ' ') sb.append(String.format("\\u%04x", c.code)) else sb.append(c)
            }
        }
        sb.append('"')
    }

    private class Parser(val s: String) {
        var i = 0
        fun eof() = i >= s.length
        fun ws() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun value(depth: Int): Any? {
            if (depth > 32) throw ParseException("nesting too deep")
            if (eof()) throw ParseException("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> if (c == '-' || c.isDigit()) num() else throw ParseException("unexpected '$c' at $i")
            }
        }
        fun lit(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) throw ParseException("bad literal at $i")
            i += word.length; return v
        }
        fun obj(depth: Int): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++; ws()
            if (i < s.length && s[i] == '}') { i++; return m }
            while (true) {
                ws()
                if (eof() || s[i] != '"') throw ParseException("expected key at $i")
                val k = str(); ws()
                if (eof() || s[i] != ':') throw ParseException("expected ':' at $i")
                i++; ws()
                m[k] = value(depth + 1); ws()
                if (eof()) throw ParseException("unterminated object")
                when (s[i]) { ',' -> i++; '}' -> { i++; return m }; else -> throw ParseException("expected ',' or '}' at $i") }
            }
        }
        fun arr(depth: Int): List<Any?> {
            val l = ArrayList<Any?>()
            i++; ws()
            if (i < s.length && s[i] == ']') { i++; return l }
            while (true) {
                ws(); l.add(value(depth + 1)); ws()
                if (eof()) throw ParseException("unterminated array")
                when (s[i]) { ',' -> i++; ']' -> { i++; return l }; else -> throw ParseException("expected ',' or ']' at $i") }
            }
        }
        fun str(): String {
            val sb = StringBuilder()
            i++
            while (true) {
                if (eof()) throw ParseException("unterminated string")
                val c = s[i++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (eof()) throw ParseException("bad escape")
                        when (val e = s[i++]) {
                            '"' -> sb.append('"'); '\\' -> sb.append('\\'); '/' -> sb.append('/')
                            'b' -> sb.append('\b'); 'f' -> sb.append('\u000c'); 'n' -> sb.append('\n')
                            'r' -> sb.append('\r'); 't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw ParseException("bad unicode escape")
                                sb.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4
                            }
                            else -> throw ParseException("bad escape \\$e")
                        }
                    }
                    else -> sb.append(c)
                }
            }
        }
        fun num(): Any {
            val start = i
            if (s[i] == '-') i++
            while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
            val t = s.substring(start, i)
            return if (t.any { it == '.' || it == 'e' || it == 'E' }) t.toDouble()
            else t.toLongOrNull() ?: t.toDouble()
        }
    }
}

// Typed accessors for untrusted maps.
fun Map<String, Any?>.str(k: String): String? = this[k] as? String
fun Map<String, Any?>.int(k: String): Int? = (this[k] as? Number)?.toInt()
fun Map<String, Any?>.long(k: String): Long? = (this[k] as? Number)?.toLong()
fun Map<String, Any?>.bool(k: String): Boolean? = this[k] as? Boolean
fun Map<String, Any?>.dbl(k: String): Double? = (this[k] as? Number)?.toDouble()
