## JSON values: how plugins and Vim describe data to each other.
##
## Vim's channel protocol speaks JSON, so every value that crosses the channel
## (an event payload, the result of an expression, the arguments to a function
## call) arrives as a `Value` value and leaves as one.
Value := [
    ## `null`, and what Vim sends for `v:null`.
    Null,
    ## `true` / `false`.
    Bool(Bool),
    ## A whole number. Vim's `Number` type. Keep line numbers and buffer
    ## numbers as `Int`: Vim refuses a `Float` where it wants a `Number`.
    Int(I64),
    ## A number with a fractional part. Vim's `Float` type.
    Float(F64),
    ## A string. Vim's `String` type.
    Text(Str),
    ## A list, in order. Vim's `List` type.
    Array(List(Value)),
    ## An object, in the order its fields were written. Vim's `Dict` type.
    Object(List((Str, Value))),
].{

    ## Encode a value as JSON text.
    ## ```
    ## Value.to_str(Value.Array([Value.Int(1), Value.Text("hi")])) == "[1,\"hi\"]"
    ## ```
    to_str : Value -> Str
    to_str = |value| encode(value)

    ## Parse JSON text.
    ## ```
    ## Value.parse("{\"a\": 1}") == Ok(Value.Object([("a", Value.Int(1))]))
    ## ```
    parse : Str -> Try(Value, [ValueErr(Str), ..])
    parse = |text| {
        bytes = text.to_utf8()
        (value, after) = parse_value(bytes, 0)?
        rest = skip_ws(bytes, after)
        if rest >= List.len(bytes) {
            Ok(value)
        } else {
            Err(ValueErr("unexpected trailing text"))
        }
    }

    ## Look up a field of an object.
    ## ```
    ## Value.get(Value.Object([("a", Value.Int(1))]), "a") == Ok(Value.Int(1))
    ## ```
    get : Value, Str -> Try(Value, [ValueErr(Str), ..])
    get = |value, field|
        match value {
            Object(fields) => {
                var $found = Err(ValueErr("no field named ${field}"))
                for (key, field_value) in fields {
                    if key == field {
                        $found = Ok(field_value)
                        break
                    }
                }
                $found
            }
            _ => Err(ValueErr("not an object, so it has no field named ${field}"))
        }

    ## Look up an element of an array by index, counting from 0.
    at : Value, U64 -> Try(Value, [ValueErr(Str), ..])
    at = |value, index|
        match value {
            Array(items) =>
                match List.get(items, index) {
                    Ok(item) => Ok(item)
                    Err(_) => Err(ValueErr("no element at index ${U64.to_str(index)}"))
                }
            _ => Err(ValueErr("not an array, so it has no elements"))
        }

    ## The string in a `Text`.
    as_str : Value -> Try(Str, [ValueErr(Str), ..])
    as_str = |value|
        match value {
            Text(text) => Ok(text)
            _ => Err(ValueErr("expected a string, got ${type_name(value)}"))
        }

    ## The whole number in an `Int`. A `Float` is rounded to the nearest whole
    ## number, because Vim writes `2.0` for some numbers that are conceptually
    ## integers.
    as_int : Value -> Try(I64, [ValueErr(Str), ..])
    as_int = |value|
        match value {
            Int(n) => Ok(n)
            Float(f) =>
                match f.round_to_i64_try() {
                    Ok(n) => Ok(n)
                    Err(_) => Err(ValueErr("number is too large to be a whole number"))
                }
            _ => Err(ValueErr("expected a number, got ${type_name(value)}"))
        }

    ## The number in an `Int` or a `Float`, as an `F64`.
    as_f64 : Value -> Try(F64, [ValueErr(Str), ..])
    as_f64 = |value|
        match value {
            Float(f) => Ok(f)
            Int(n) => Ok(n.to_f64())
            _ => Err(ValueErr("expected a number, got ${type_name(value)}"))
        }

    ## The boolean in a `Bool`. Vim has no boolean type of its own, so it sends
    ## `0` and `1`; those count too.
    as_bool : Value -> Try(Bool, [ValueErr(Str), ..])
    as_bool = |value|
        match value {
            Bool(b) => Ok(b)
            Int(0) => Ok(False)
            Int(_) => Ok(True)
            _ => Err(ValueErr("expected a boolean, got ${type_name(value)}"))
        }

    ## The elements of an `Array`.
    as_list : Value -> Try(List(Value), [ValueErr(Str), ..])
    as_list = |value|
        match value {
            Array(items) => Ok(items)
            _ => Err(ValueErr("expected an array, got ${type_name(value)}"))
        }

    ## The fields of an `Object`, in the order they appeared.
    as_object : Value -> Try(List((Str, Value)), [ValueErr(Str), ..])
    as_object = |value|
        match value {
            Object(fields) => Ok(fields)
            _ => Err(ValueErr("expected an object, got ${type_name(value)}"))
        }

    ## The string in a `Text`, or the given fallback for anything else.
    str_or : Value, Str -> Str
    str_or = |value, fallback|
        match as_str(value) {
            Ok(text) => text
            Err(_) => fallback
        }

    ## The number in an `Int` or `Float`, or the given fallback.
    int_or : Value, I64 -> I64
    int_or = |value, fallback|
        match as_int(value) {
            Ok(n) => n
            Err(_) => fallback
        }

    ## The value of an object field, or `Null` if there is no such field.
    field_or_null : Value, Str -> Value
    field_or_null = |value, field|
        match get(value, field) {
            Ok(found) => found
            Err(_) => Value.Null
        }

    ## Whether two values are the same. This is what `==` uses.
    is_eq : Value, Value -> Bool
    is_eq = |left, right|
        match (left, right) {
            (Null, Null) => True
            (Bool(a), Bool(b)) => a == b
            (Int(a), Int(b)) => a == b
            (Float(a), Float(b)) => a == b
            (Int(a), Float(b)) => a.to_f64() == b
            (Float(a), Int(b)) => a == b.to_f64()
            (Text(a), Text(b)) => a == b
            (Array(a), Array(b)) => {
                if List.len(a) != List.len(b) {
                    False
                } else {
                    var $same = True
                    for index in 0..<List.len(a) {
                        match (List.get(a, index), List.get(b, index)) {
                            (Ok(x), Ok(y)) =>
                                if !is_eq(x, y) {
                                    $same = False
                                    break
                                } else {
                                    {}
                                }
                            _ => {
                                $same = False
                                break
                            }
                        }
                    }
                    $same
                }
            }
            (Object(a), Object(b)) => {
                if List.len(a) != List.len(b) {
                    False
                } else {
                    var $same = True
                    for index in 0..<List.len(a) {
                        match (List.get(a, index), List.get(b, index)) {
                            (Ok((key_a, value_a)), Ok((key_b, value_b))) =>
                                if key_a != key_b or !is_eq(value_a, value_b) {
                                    $same = False
                                    break
                                } else {
                                    {}
                                }
                            _ => {
                                $same = False
                                break
                            }
                        }
                    }
                    $same
                }
            }
            _ => False
        }

    ## A one-word description of which kind of value this is, for error messages.
    type_name : Value -> Str
    type_name = |value|
        match value {
            Null => "null"
            Bool(_) => "a boolean"
            Int(_) => "a number"
            Float(_) => "a number"
            Text(_) => "a string"
            Array(_) => "an array"
            Object(_) => "an object"
        }
}

# =============================================================================
# Encoding
# =============================================================================

encode : Value -> Str
encode = |value|
    match value {
        Null => "null"
        Bool(b) => if b "true" else "false"
        Int(n) => I64.to_str(n)
        Float(f) => F64.to_str(f)
        Text(text) => encode_str(text)
        Array(items) => {
            var $parts = []
            for item in items {
                $parts = $parts.append(encode(item))
            }
            "[${Str.join_with($parts, ",")}]"
        }
        Object(fields) => {
            var $parts = []
            for (key, field_value) in fields {
                $parts = $parts.append("${encode_str(key)}:${encode(field_value)}")
            }
            "{${Str.join_with($parts, ",")}}"
        }
    }

encode_str : Str -> Str
encode_str = |text| {
    var $out = [34]
    for byte in text.to_utf8() {
        if byte == '"' {
            $out = $out.concat([92, 34])
        } else if byte == '\\' {
            $out = $out.concat([92, 92])
        } else if byte == '\n' {
            $out = $out.concat([92, 'n'])
        } else if byte == '\r' {
            $out = $out.concat([92, 'r'])
        } else if byte == '\t' {
            $out = $out.concat([92, 't'])
        } else if byte < 0x20 {
            $out = $out.concat([92, 'u', '0', '0', hex_digit(byte // 16), hex_digit(byte % 16)])
        } else {
            $out = $out.append(byte)
        }
    }
    $out = $out.append(34)
    match Str.from_utf8($out) {
        Ok(encoded) => encoded
        # Unreachable: the input was a Str, and every byte written above is
        # either copied from it or ASCII.
        Err(_) => "\"\""
    }
}

hex_digit : U8 -> U8
hex_digit = |n| if n < 10 ('0' + n) else ('a' + (n - 10))

# =============================================================================
# Parsing
# =============================================================================

skip_ws : List(U8), U64 -> U64
skip_ws = |bytes, start| {
    var $index = start
    while $index < List.len(bytes) {
        match List.get(bytes, $index) {
            Ok(byte) =>
                if byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' {
                    $index = $index + 1
                } else {
                    break
                }
            Err(_) => break
        }
    }
    $index
}

byte_at : List(U8), U64 -> Try(U8, [ValueErr(Str), ..])
byte_at = |bytes, index|
    match List.get(bytes, index) {
        Ok(byte) => Ok(byte)
        Err(_) => Err(ValueErr("unexpected end of JSON input"))
    }

parse_value : List(U8), U64 -> Try((Value, U64), [ValueErr(Str), ..])
parse_value = |bytes, start| {
    index = skip_ws(bytes, start)
    byte = byte_at(bytes, index)?
    if byte == '{' {
        parse_object(bytes, index + 1)
    } else if byte == '[' {
        parse_array(bytes, index + 1)
    } else if byte == '"' {
        (text, after) = parse_str(bytes, index + 1)?
        Ok((Value.Text(text), after))
    } else if byte == 't' {
        expect_word(bytes, index, "true")?
        Ok((Value.Bool(True), index + 4))
    } else if byte == 'f' {
        expect_word(bytes, index, "false")?
        Ok((Value.Bool(False), index + 5))
    } else if byte == 'n' {
        expect_word(bytes, index, "null")?
        Ok((Value.Null, index + 4))
    } else {
        parse_number(bytes, index)
    }
}

expect_word : List(U8), U64, Str -> Try({}, [ValueErr(Str), ..])
expect_word = |bytes, start, word| {
    word_bytes = word.to_utf8()
    var $offset = 0
    var $result = Ok({})
    for expected in word_bytes {
        match List.get(bytes, start + $offset) {
            Ok(actual) =>
                if actual != expected {
                    $result = Err(ValueErr("expected ${word}"))
                    break
                } else {
                    $offset = $offset + 1
                }
            Err(_) => {
                $result = Err(ValueErr("expected ${word}"))
                break
            }
        }
    }
    $result
}

parse_array : List(U8), U64 -> Try((Value, U64), [ValueErr(Str), ..])
parse_array = |bytes, start| {
    var $index = skip_ws(bytes, start)
    var $items = []
    var $result = Err(ValueErr("unterminated array"))
    if byte_at(bytes, $index)? == ']' {
        Ok((Value.Array([]), $index + 1))
    } else {
        while True {
            (item, after) = parse_value(bytes, $index)?
            $items = $items.append(item)
            $index = skip_ws(bytes, after)
            next = byte_at(bytes, $index)?
            if next == ',' {
                $index = $index + 1
            } else if next == ']' {
                $result = Ok((Value.Array($items), $index + 1))
                break
            } else {
                $result = Err(ValueErr("expected , or ] in array"))
                break
            }
        }
        $result
    }
}

parse_object : List(U8), U64 -> Try((Value, U64), [ValueErr(Str), ..])
parse_object = |bytes, start| {
    var $index = skip_ws(bytes, start)
    var $fields = []
    var $result = Err(ValueErr("unterminated object"))
    if byte_at(bytes, $index)? == '}' {
        Ok((Value.Object([]), $index + 1))
    } else {
        while True {
            $index = skip_ws(bytes, $index)
            if byte_at(bytes, $index)? != '"' {
                $result = Err(ValueErr("expected a field name in object"))
                break
            } else {
                (key, after_key) = parse_str(bytes, $index + 1)?
                $index = skip_ws(bytes, after_key)
                if byte_at(bytes, $index)? != ':' {
                    $result = Err(ValueErr("expected : after field name"))
                    break
                } else {
                    (field_value, after_value) = parse_value(bytes, $index + 1)?
                    $fields = $fields.append((key, field_value))
                    $index = skip_ws(bytes, after_value)
                    next = byte_at(bytes, $index)?
                    if next == ',' {
                        $index = $index + 1
                    } else if next == '}' {
                        $result = Ok((Value.Object($fields), $index + 1))
                        break
                    } else {
                        $result = Err(ValueErr("expected , or } in object"))
                        break
                    }
                }
            }
        }
        $result
    }
}

parse_str : List(U8), U64 -> Try((Str, U64), [ValueErr(Str), ..])
parse_str = |bytes, start| {
    var $index = start
    var $out = []
    var $result = Err(ValueErr("unterminated string"))
    while True {
        byte = byte_at(bytes, $index)?
        if byte == '"' {
            match Str.from_utf8($out) {
                Ok(text) => {
                    $result = Ok((text, $index + 1))
                    break
                }
                Err(_) => {
                    $result = Err(ValueErr("string was not valid UTF-8"))
                    break
                }
            }
        } else if byte == '\\' {
            escaped = byte_at(bytes, $index + 1)?
            if escaped == 'u' {
                (code_point, after) = parse_escape_u(bytes, $index + 2)?
                $out = push_code_point($out, code_point)
                $index = after
            } else {
                $out = $out.append(unescape(escaped))
                $index = $index + 2
            }
        } else {
            $out = $out.append(byte)
            $index = $index + 1
        }
    }
    $result
}

unescape : U8 -> U8
unescape = |byte|
    if byte == 'n' {
        '\n'
    } else if byte == 't' {
        '\t'
    } else if byte == 'r' {
        '\r'
    } else if byte == 'b' {
        8
    } else if byte == 'f' {
        12
    } else {
        # `\"`, `\\`, `\/`, and anything else: the character itself.
        byte
    }

## Parse the four hex digits after a `\u`, plus a following `\uXXXX` when the
## first one is the high half of a surrogate pair.
parse_escape_u : List(U8), U64 -> Try((U32, U64), [ValueErr(Str), ..])
parse_escape_u = |bytes, start| {
    high = parse_hex4(bytes, start)?
    if high >= 0xD800 and high <= 0xDBFF {
        # A high surrogate: the code point is split across two escapes.
        match (List.get(bytes, start + 4), List.get(bytes, start + 5)) {
            (Ok(92), Ok(117)) => {
                low = parse_hex4(bytes, start + 6)?
                if low >= 0xDC00 and low <= 0xDFFF {
                    combined = 0x10000 + ((high - 0xD800) * 0x400) + (low - 0xDC00)
                    Ok((combined, start + 10))
                } else {
                    Ok((high, start + 4))
                }
            }
            _ => Ok((high, start + 4))
        }
    } else {
        Ok((high, start + 4))
    }
}

parse_hex4 : List(U8), U64 -> Try(U32, [ValueErr(Str), ..])
parse_hex4 = |bytes, start| {
    var $value = 0
    var $offset = 0
    var $result = Ok(0)
    while $offset < 4 {
        byte = byte_at(bytes, start + $offset)?
        digit =
            if byte >= '0' and byte <= '9' {
                byte - '0'
            } else if byte >= 'a' and byte <= 'f' {
                (byte - 'a') + 10
            } else if byte >= 'A' and byte <= 'F' {
                (byte - 'A') + 10
            } else {
                99
            }
        if digit == 99 {
            $result = Err(ValueErr("invalid \\u escape"))
            break
        } else {
            $value = ($value * 16) + digit.to_u32()
            $offset = $offset + 1
            $result = Ok($value)
        }
    }
    $result
}

## Append one Unicode code point to a UTF-8 byte list.
push_code_point : List(U8), U32 -> List(U8)
push_code_point = |bytes, code_point|
    if code_point < 0x80 {
        bytes.append(code_point.to_u8_wrap())
    } else if code_point < 0x800 {
        bytes.concat([
            (0xC0 + (code_point // 64)).to_u8_wrap(),
            (0x80 + (code_point % 64)).to_u8_wrap(),
        ])
    } else if code_point < 0x10000 {
        bytes.concat([
            (0xE0 + (code_point // 4096)).to_u8_wrap(),
            (0x80 + ((code_point // 64) % 64)).to_u8_wrap(),
            (0x80 + (code_point % 64)).to_u8_wrap(),
        ])
    } else {
        bytes.concat([
            (0xF0 + (code_point // 262144)).to_u8_wrap(),
            (0x80 + ((code_point // 4096) % 64)).to_u8_wrap(),
            (0x80 + ((code_point // 64) % 64)).to_u8_wrap(),
            (0x80 + (code_point % 64)).to_u8_wrap(),
        ])
    }

parse_number : List(U8), U64 -> Try((Value, U64), [ValueErr(Str), ..])
parse_number = |bytes, start| {
    var $index = start
    var $is_float = False
    if byte_at(bytes, $index)? == '-' {
        $index = $index + 1
    }
    while $index < List.len(bytes) {
        match List.get(bytes, $index) {
            Ok(byte) =>
                if byte >= '0' and byte <= '9' {
                    $index = $index + 1
                } else if byte == '.' or byte == 'e' or byte == 'E' {
                    $is_float = True
                    $index = $index + 1
                } else if byte == '+' or byte == '-' {
                    # Only valid right after an exponent marker; the parse below
                    # rejects anything else.
                    $index = $index + 1
                } else {
                    break
                }
            Err(_) => break
        }
    }
    if $index == start {
        Err(ValueErr("expected a JSON value"))
    } else {
        digits = bytes.sublist({ start: start, len: $index - start })
        text =
            match Str.from_utf8(digits) {
                Ok(parsed) => parsed
                Err(_) => ""
            }
        if $is_float {
            match F64.from_str(text) {
                Ok(f) => Ok((Value.Float(f), $index))
                Err(_) => Err(ValueErr("invalid number: ${text}"))
            }
        } else {
            match I64.from_str(text) {
                Ok(n) => Ok((Value.Int(n), $index))
                Err(_) =>
                    match F64.from_str(text) {
                        Ok(f) => Ok((Value.Float(f), $index))
                        Err(_) => Err(ValueErr("invalid number: ${text}"))
                    }
            }
        }
    }
}

# =============================================================================
# Tests
#
# This is the whole channel protocol's encoding, so a mistake here is a
# mistake in every value that crosses into or out of a plugin. It had no
# tests until now; `roc test Value.roc` runs these.
# =============================================================================

## Whether a Try came back as an error - only used by the tests below.
is_err : Try(a, e) -> Bool
is_err = |result|
    match result {
        Ok(_) => Bool.False
        Err(_) => Bool.True
    }

# --- round trips -------------------------------------------------------

expect Value.parse(Value.to_str(Value.Null)) == Ok(Value.Null)
expect Value.parse(Value.to_str(Value.Bool(True))) == Ok(Value.Bool(True))
expect Value.parse(Value.to_str(Value.Bool(False))) == Ok(Value.Bool(False))
expect Value.parse(Value.to_str(Value.Int(-42))) == Ok(Value.Int(-42))
expect Value.parse(Value.to_str(Value.Text("hi \"there\"\n"))) == Ok(Value.Text("hi \"there\"\n"))

round_trip_array : Value
round_trip_array = Value.Array([Value.Int(1), Value.Text("two"), Value.Null])

expect Value.parse(Value.to_str(round_trip_array)) == Ok(round_trip_array)

round_trip_object : Value
round_trip_object = Value.Object([("a", Value.Int(1)), ("b", Value.Array([]))])

expect Value.parse(Value.to_str(round_trip_object)) == Ok(round_trip_object)

# --- encoding: literal text, matched against what Vim's own JSON expects ---

expect Value.to_str(Value.Null) == "null"
expect Value.to_str(Value.Bool(True)) == "true"
expect Value.to_str(Value.Bool(False)) == "false"
expect Value.to_str(Value.Int(7)) == "7"
expect Value.to_str(Value.Text("hi")) == "\"hi\""
expect Value.to_str(Value.Array([Value.Int(1), Value.Int(2)])) == "[1,2]"
expect Value.to_str(Value.Object([("a", Value.Int(1))])) == "{\"a\":1}"
# Field order is kept, not sorted.
expect Value.to_str(Value.Object([("b", Value.Int(2)), ("a", Value.Int(1))])) == "{\"b\":2,\"a\":1}"

# A string with characters JSON cannot write literally.
expect Value.to_str(Value.Text("a\"b\\c\nd\te")) == "\"a\\\"b\\\\c\\nd\\te\""
# A control character with no short escape falls back to \u00XX.
expect Value.to_str(Value.Text("\u(0001)")) == "\"\\u0001\""

# --- parsing -------------------------------------------------------------

expect Value.parse("null") == Ok(Value.Null)
expect Value.parse("true") == Ok(Value.Bool(True))
expect Value.parse("false") == Ok(Value.Bool(False))
expect Value.parse("0") == Ok(Value.Int(0))
expect Value.parse("-17") == Ok(Value.Int(-17))
expect Value.parse("3.5") == Ok(Value.Float(3.5))
expect Value.parse("2e3") == Ok(Value.Float(2000.0))
expect Value.parse("\"\"") == Ok(Value.Text(""))
expect Value.parse("  \n  42  \n  ") == Ok(Value.Int(42))
expect Value.parse("[]") == Ok(Value.Array([]))
expect Value.parse("{}") == Ok(Value.Object([]))
expect Value.parse("[1, 2, 3]") == Ok(Value.Array([Value.Int(1), Value.Int(2), Value.Int(3)]))
expect Value.parse("[[1],[2]]") == Ok(Value.Array([Value.Array([Value.Int(1)]), Value.Array([Value.Int(2)])]))
expect
    Value.parse("{\"a\": 1, \"b\": [true, null]}")
    == Ok(Value.Object([("a", Value.Int(1)), ("b", Value.Array([Value.Bool(True), Value.Null]))]))

# What Vim actually sends: a Notify envelope with nested data.
expect
    Value.parse("{\"event\":\"BufWritePost\",\"data\":{\"file\":\"a.md\",\"buffer\":3}}")
    == Ok(
        Value.Object(
            [
                ("event", Value.Text("BufWritePost")),
                ("data", Value.Object([("file", Value.Text("a.md")), ("buffer", Value.Int(3))])),
            ],
        ),
    )

# Backslash escapes.
expect Value.parse("\"a\\nb\"") == Ok(Value.Text("a\nb"))
expect Value.parse("\"a\\tb\"") == Ok(Value.Text("a\tb"))
expect Value.parse("\"a\\\"b\"") == Ok(Value.Text("a\"b"))
expect Value.parse("\"a\\\\b\"") == Ok(Value.Text("a\\b"))
expect Value.parse("\"a\\/b\"") == Ok(Value.Text("a/b"))

# \u escapes, including one outside the BMP via a surrogate pair.
expect Value.parse("\"\\u0041\"") == Ok(Value.Text("A"))
expect Value.parse("\"\\ud83d\\ude00\"") == Ok(Value.Text("\u(1F600)")) # 😀
# A lone high surrogate (no partner follows) is not a valid code point on its
# own, so parsing reports an error rather than producing invalid UTF-8.
expect Value.parse("\"\\ud83d!\"") |> is_err

# Trailing text after a complete value is an error, not a silent truncation.
expect Value.parse("1 2") |> is_err
expect Value.parse("") |> is_err
expect Value.parse("{") |> is_err
expect Value.parse("[1,]") |> is_err
expect Value.parse("\"unterminated") |> is_err
expect Value.parse("\"\\uZZZZ\"") |> is_err

# --- accessors -------------------------------------------------------------

expect Value.get(Value.Object([("a", Value.Int(1))]), "a") == Ok(Value.Int(1))
expect Value.get(Value.Object([("a", Value.Int(1))]), "b") |> is_err
expect Value.get(Value.Int(1), "a") |> is_err

expect Value.at(Value.Array([Value.Int(10), Value.Int(20)]), 1) == Ok(Value.Int(20))
expect Value.at(Value.Array([Value.Int(10)]), 5) |> is_err

expect Value.as_str(Value.Text("hi")) == Ok("hi")
expect Value.as_str(Value.Int(1)) |> is_err
expect Value.as_int(Value.Int(5)) == Ok(5)
# A whole-valued Float still answers as_int: Vim's own Number/Float split
# does not always line up with which one a given expression evaluates to.
expect Value.as_int(Value.Float(5.0)) == Ok(5)
expect Value.as_int(Value.Float(5.9)) == Ok(6)
expect Value.as_int(Value.Text("5")) |> is_err
expect Value.as_f64(Value.Int(5)) == Ok(5.0)
expect Value.as_f64(Value.Float(2.5)) == Ok(2.5)
expect Value.as_bool(Value.Bool(True)) == Ok(True)
expect Value.as_list(Value.Array([Value.Int(1)])) == Ok([Value.Int(1)])
expect Value.as_object(Value.Object([("a", Value.Int(1))])) == Ok([("a", Value.Int(1))])

expect Value.str_or(Value.Text("hi"), "default") == "hi"
expect Value.str_or(Value.Int(1), "default") == "default"
expect Value.int_or(Value.Int(9), 0) == 9
expect Value.int_or(Value.Text("nope"), 0) == 0
expect Value.field_or_null(Value.Object([("a", Value.Int(1))]), "a") == Value.Int(1)
expect Value.field_or_null(Value.Object([]), "missing") == Value.Null
expect Value.field_or_null(Value.Int(1), "a") == Value.Null

# --- equality and type names ------------------------------------------------

expect Value.Int(1) == Value.Int(1)
expect Value.Int(1) != Value.Int(2)
expect Value.Int(1) != Value.Text("1")
# A number equals itself across Int and Float, the way Vim treats numbers.
expect Value.is_eq(Value.Int(3), Value.Float(3.0))
expect Value.Array([Value.Int(1), Value.Int(2)]) == Value.Array([Value.Int(1), Value.Int(2)])
expect Value.Array([Value.Int(1)]) != Value.Array([Value.Int(1), Value.Int(2)])
# Object equality cares about order: it is how Vim's Dict prints, and the
# protocol relies on it for the envelope shape.
expect Value.Object([("a", Value.Int(1)), ("b", Value.Int(2))]) != Value.Object([("b", Value.Int(2)), ("a", Value.Int(1))])

expect Value.type_name(Value.Null) == "null"
expect Value.type_name(Value.Array([])) == "an array"
expect Value.type_name(Value.Object([])) == "an object"
