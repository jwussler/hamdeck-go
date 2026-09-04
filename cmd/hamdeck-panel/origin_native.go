//go:build !js

package main

// On a desktop there is no page to inherit from: the operator says where the
// station is, and there is deliberately no default host compiled in.
func defaultBase() string { return "" }
