//go:build js

package main

import "syscall/js"

// ⚠️ IN A BROWSER THERE ARE NO COMMAND-LINE FLAGS, and the first build of this
// panel took its host from one - so served as WebAssembly it built the address
// "http://" and failed with no explanation. The page knows where it came from;
// ask it.
func defaultBase() string {
	loc := js.Global().Get("location")
	if loc.IsUndefined() {
		return ""
	}
	return loc.Get("origin").String()
}
