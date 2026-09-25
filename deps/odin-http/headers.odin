package http

import "core:strings"

// A case-insensitive ASCII map for storing headers.
Headers :: struct {
	_kv:      map[string]string,
	readonly: bool,
}

headers_init :: proc(h: ^Headers, allocator := context.temp_allocator) {
	h._kv.allocator = allocator
}

headers_count :: #force_inline proc(h: Headers) -> int {
	return len(h._kv)
}

/*
Sets a header, given key is first sanitized, final (sanitized) key is returned.
*/
headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) -> string {
	if h.readonly {
		panic("these headers are readonly, did you accidentally try to set a header on the request?", loc)
	}

	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	l := sanitize_key(h^, k)
	key_ptr, value_ptr, just_inserted, _ := map_entry(&h._kv, l)
	if !just_inserted {
		delete(l, allocator)
	}
	value_ptr^ = v
	return key_ptr^
}

/*
Unsafely set header, given key is assumed to be a lowercase string and to be without newlines.
*/
headers_set_unsafe :: #force_inline proc(h: ^Headers, k: string, v: string, loc := #caller_location) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	h._kv[k] = v
}

headers_get :: proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	l := sanitize_key(h, k)
	defer delete(l, allocator)
	return h._kv[l]
}

/*
Unsafely get header, given key is assumed to be a lowercase string.
*/
headers_get_unsafe :: #force_inline proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[k]
}

headers_entry :: proc(h: ^Headers, k: string, loc := #caller_location) -> (key_ptr: ^string, value_ptr: ^string, just_inserted: bool) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	l := sanitize_key(h^, k)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&h._kv, l)
	if !just_inserted {
		delete(l, allocator)
	}
	return
}

headers_entry_unsafe :: #force_inline proc(h: ^Headers, k: string, loc := #caller_location) -> (key_ptr: ^string, value_ptr: ^string, just_inserted: bool) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
	key_ptr, value_ptr, just_inserted, _ = map_entry(&h._kv, k)
	return
}

headers_has :: proc(h: Headers, k: string) -> bool {
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	l := sanitize_key(h, k)
	defer delete(l, allocator)
	return l in h._kv
}

/*
Unsafely check for a header, given key is assumed to be a lowercase string.
*/
headers_has_unsafe :: #force_inline proc(h: Headers, k: string) -> bool {
	return k in h._kv
}

headers_delete :: proc(h: ^Headers, k: string) -> (deleted_key: string, deleted_value: string) {
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
	l := sanitize_key(h^, k)
	defer delete(l, allocator)
	return delete_key(&h._kv, l)
}

/*
Unsafely delete a header, given key is assumed to be a lowercase string.
*/
headers_delete_unsafe :: #force_inline proc(h: ^Headers, k: string) {
	delete_key(&h._kv, k)
}

/* Common Helpers */

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(h: ^Headers, ct: string) {
	headers_set_unsafe(h, "content-type", ct)
}

headers_set_content_type_mime :: #force_inline proc(h: ^Headers, ct: Mime_Type) {
	headers_set_unsafe(h, "content-type", mime_to_content_type(ct))
}

headers_set_close :: #force_inline proc(h: ^Headers) {
	headers_set_unsafe(h, "connection", "close")
}

/*
Escapes any newlines and converts ASCII to lowercase.
*/
@(private="package")
sanitize_key :: proc(h: Headers, k: string) -> string {
	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator

	// general +4 in rare case of newlines, so we might not need to reallocate.
	b := strings.builder_make(0, len(k)+4, allocator)
	for c in k {
		switch c {
		case 'A'..='Z': strings.write_rune(&b, c + 32)
		case '\n':      strings.write_string(&b, "\\n")
		case:           strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)

	// NOTE: implementation that only allocates if needed, but we use arena's anyway so just allocating
	// some space should be about as fast?
	//
	// b: strings.Builder = ---
	// i: int
	// for c in v {
	// 	if c == '\n' || (c >= 'A' && c <= 'Z') {
	// 		b = strings.builder_make(0, len(v)+4, allocator)
	// 		strings.write_string(&b, v[:i])
	// 		alloc = true
	// 		break
	// 	}
	// 	i+=1
	// }
	//
	// if !alloc {
	// 	return v, false
	// }
	//
	// for c in v[i:] {
	//  switch c {
	//  case 'A'..='Z': strings.write_rune(&b, c + 32)
	//  case '\n':      strings.write_string(&b, "\\n")
	//  case:           strings.write_rune(&b, c)
	//  }
	// }
	//
	// return strings.to_string(b), true
}

import "core:testing"

@(test)
test_headers_transient_sanitized_keys_are_freed :: proc(t: ^testing.T) {
	h: Headers
	headers_init(&h, context.allocator)
	defer delete(h._kv)

	stored_key := headers_set(&h, "Content-Type", "application/json")
	testing.expect_value(t, stored_key, "content-type")

	value, found := headers_get(h, "CONTENT-Type")
	testing.expect(t, found)
	testing.expect_value(t, value, "application/json")
	testing.expect(t, headers_has(h, "Content-TYPE"))

	deleted_key, deleted_value := headers_delete(&h, "CONTENT-TYPE")
	testing.expect_value(t, deleted_key, "content-type")
	testing.expect_value(t, deleted_value, "application/json")
	delete(deleted_key, context.allocator)
}

@(test)
test_headers_reused_sanitized_keys_are_freed :: proc(t: ^testing.T) {
	h: Headers
	headers_init(&h, context.allocator)
	defer delete(h._kv)

	first_key := headers_set(&h, "X-Request-ID", "first")
	second_key := headers_set(&h, "X-REQUEST-ID", "second")
	testing.expect_value(t, first_key, "x-request-id")
	testing.expect_value(t, second_key, first_key)
	testing.expect_value(t, headers_get(h, "x-request-id"), "second")

	key_ptr, value_ptr, just_inserted := headers_entry(&h, "X-Request-ID")
	testing.expect(t, !just_inserted)
	testing.expect_value(t, key_ptr^, first_key)
	testing.expect_value(t, value_ptr^, "second")

	deleted_key, _ := headers_delete(&h, "X-Request-ID")
	delete(deleted_key, context.allocator)
}
