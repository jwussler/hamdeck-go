package auth

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Store is where accounts live: a file on the station, not a line in the binary.
//
// ⚠️ NOTHING ABOUT AN ACCOUNT BELONGS IN CODE. The host used to take a single
// hash from an environment variable and attach it to a username spelled "admin"
// in main.go, so the only supported way to change the operator's own name was to
// edit Go and rebuild - and there was no supported way at all to reset a
// forgotten password from a terminal. That is tolerable on a box you own and
// wrong for something other people will run.
//
// ⚠️ THE FILE IS THE RECOVERY PATH. Whoever can reach the machine can fix the
// login with `hamdeck-host users set <name>` and nothing else installed - no
// panel, no session, no network. That is the whole point of putting it here.
type Store struct {
	path string
}

// User is one account as it is written down.
//
// ⚠️ THE HASH, NEVER THE PASSWORD. PBKDF2-HMAC-SHA256 at 350000 iterations, the
// same format the C++ host used, so an existing station's accounts move across
// without anybody re-enrolling.
type User struct {
	Username    string `json:"username"`
	Hash        string `json:"hash"`
	CanTransmit bool   `json:"can_transmit"`
	IsAdmin     bool   `json:"is_admin"`
	IsStation   bool   `json:"is_station"`
}

type storeFile struct {
	// A note to whoever opens this file at 3 a.m. looking for a way back in.
	Comment string `json:"_comment"`
	Users   []User `json:"users"`
}

const storeComment = "HamDeck accounts. Passwords are PBKDF2 hashes, never plaintext. " +
	"To reset one: hamdeck-host users set <username>"

func NewStore(path string) *Store { return &Store{path: path} }

func (s *Store) Path() string { return s.path }

// Load reads the accounts.
//
// ⚠️ A MISSING FILE AND AN UNREADABLE ONE ARE DIFFERENT ANSWERS. "Not there yet"
// is a fresh install; "permission denied" is a host that will come up with no
// users and look exactly like a fresh install while the accounts sit on disk
// three feet away. The second one has to be an error, or the operator is told to
// re-enrol everybody to fix a chmod.
func (s *Store) Load() ([]User, error) {
	b, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %w", s.path, err)
	}
	var f storeFile
	if err := json.Unmarshal(b, &f); err != nil {
		// ⚠️ Refuse rather than start empty. A truncated write or a hand edit
		// with a trailing comma would otherwise silently become "this station
		// has no accounts", which is indistinguishable from a fresh install and
		// invites somebody to "fix" it by creating a new admin.
		return nil, fmt.Errorf("%s is not valid JSON: %w", s.path, err)
	}
	return f.Users, nil
}

// ModTime is how the running host notices a reset done from a terminal.
func (s *Store) ModTime() time.Time {
	fi, err := os.Stat(s.path)
	if err != nil {
		return time.Time{}
	}
	return fi.ModTime()
}

// Save writes the accounts, atomically, and keeps the file private.
//
// ⚠️ TEMP FILE THEN RENAME. A crash halfway through a direct write leaves a
// truncated file, and the next start finds a station with no accounts on it.
//
// ⚠️ AND IT PRESERVES OWNERSHIP, WHICH IS THE LOCKOUT NOBODY SEES COMING. The
// service runs as an ordinary user; the reset command is run with sudo. Writing
// a fresh root:root 0600 file leaves the host unable to READ its own accounts on
// the next restart - a password reset that locks the station out of itself. So
// the new file is given the owner of the file it replaces, or of the directory
// it sits in.
func (s *Store) Save(users []User) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	sort.Slice(users, func(i, j int) bool { return users[i].Username < users[j].Username })
	b, err := json.MarshalIndent(storeFile{Comment: storeComment, Users: users}, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return fmt.Errorf("cannot write %s: %w", tmp, err)
	}
	if uid, gid, ok := ownerToInherit(s.path); ok {
		if err := os.Chown(tmp, uid, gid); err != nil && os.Geteuid() == 0 {
			os.Remove(tmp)
			return fmt.Errorf("cannot set the owner of %s: %w", tmp, err)
		}
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("cannot replace %s: %w", s.path, err)
	}
	return os.Chmod(s.path, 0o600)
}

// Warnings reports anything about the file that would bite later, in words that
// say what to do about it. Empty means it is fine.
func (s *Store) Warnings() []string {
	var out []string
	fi, err := os.Stat(s.path)
	if err != nil {
		return nil
	}
	if m := fi.Mode().Perm(); m&0o077 != 0 {
		out = append(out, fmt.Sprintf(
			"%s is mode %04o - it holds password hashes and should be 0600: chmod 600 %s",
			s.path, m, s.path))
	}
	return out
}
