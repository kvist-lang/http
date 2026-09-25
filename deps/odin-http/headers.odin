package http

import "core:mem"

// A case-insensitive ASCII map for storing headers.
Headers :: struct {
	_kv:      map[string]string,
	readonly: bool,
}

headers_init :: proc(h: ^Headers, allocator := context.temp_allocator) {
	h._kv.allocator = allocator
}

@(private="file")
headers_allocator :: #force_inline proc(h: Headers) -> mem.Allocator {
	return h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator
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

	key_ptr, value_ptr, _ := headers_entry(h, k, loc)
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
	l := sanitize_key(h, k)
	defer sanitized_key_destroy(h, l)
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
	allocator := headers_allocator(h^)
	l := sanitize_key(h^, k)
	entry_err: mem.Allocator_Error
	key_ptr, value_ptr, just_inserted, entry_err = map_entry(&h._kv, l)
	if entry_err != nil {
		delete(l, allocator)
		panic("failed to allocate header entry", loc)
	}
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
	l := sanitize_key(h, k)
	defer sanitized_key_destroy(h, l)
	return l in h._kv
}

/*
Unsafely check for a header, given key is assumed to be a lowercase string.
*/
headers_has_unsafe :: #force_inline proc(h: Headers, k: string) -> bool {
	return k in h._kv
}

headers_delete :: proc(h: ^Headers, k: string) -> (deleted_key: string, deleted_value: string) {
	l := sanitize_key(h^, k)
	defer sanitized_key_destroy(h^, l)
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
	sanitized_len := len(k)
	for c in transmute([]byte)k {
		if c == '\n' {
			sanitized_len += 1
		}
	}

	b := make([]byte, sanitized_len, headers_allocator(h))
	i := 0
	for c in transmute([]byte)k {
		switch c {
		case 'A'..='Z':
			b[i] = c + 32
			i += 1
		case '\n':
			b[i] = '\\'
			b[i + 1] = 'n'
			i += 2
		case:
			b[i] = c
			i += 1
		}
	}
	return string(b)
}

@(private="package")
sanitized_key_destroy :: #force_inline proc(h: Headers, k: string) {
	delete(k, headers_allocator(h))
}

import "core:testing"

@(test)
test_headers_transient_sanitized_keys_are_freed :: proc(t: ^testing.T) {
	h: Headers
	headers_init(&h, context.allocator)
	defer delete(h._kv)

	stored_key := headers_set(&h, "Content\nType", "application/json")
	testing.expect_value(t, stored_key, "content\\ntype")

	value, found := headers_get(h, "CONTENT\nType")
	testing.expect(t, found)
	testing.expect_value(t, value, "application/json")
	testing.expect(t, headers_has(h, "Content\nTYPE"))

	deleted_key, deleted_value := headers_delete(&h, "CONTENT\nTYPE")
	testing.expect_value(t, deleted_key, "content\\ntype")
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
