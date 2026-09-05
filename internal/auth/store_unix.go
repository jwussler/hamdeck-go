//go:build unix

package auth

import (
	"os"
	"path/filepath"
	"syscall"
)

// ownerToInherit answers who a rewritten accounts file should belong to.
//
// ⚠️ THE FILE IT REPLACES FIRST, THEN THE DIRECTORY IT LIVES IN. `sudo hamdeck-host
// users set` runs as root; the service does not. Handing the new file root's
// ownership would lock the host out of its own accounts at the next restart -
// a password reset that takes the station down, discovered hours later.
func ownerToInherit(path string) (uid, gid int, ok bool) {
	if fi, err := os.Stat(path); err == nil {
		if st, good := fi.Sys().(*syscall.Stat_t); good {
			return int(st.Uid), int(st.Gid), true
		}
	}
	if fi, err := os.Stat(filepath.Dir(path)); err == nil {
		if st, good := fi.Sys().(*syscall.Stat_t); good {
			return int(st.Uid), int(st.Gid), true
		}
	}
	return 0, 0, false
}
