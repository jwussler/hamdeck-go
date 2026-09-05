package auth

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func newTestService(t *testing.T) (*Service, *Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "users.json")
	store := NewStore(path)
	s := New(store, 480)
	if err := s.Load(); err != nil {
		t.Fatalf("loading a store that does not exist yet must not be an error: %v", err)
	}
	return s, store, path
}

// ⚠️ THE ASSERTIONS THAT MATTER ARE THE NEGATIVE ONES. That a correct password
// works is the easy half; what protects a transmitter is that a wrong one does
// not, that an unknown user is refused the same way, and that a token nobody
// issued is not a session.
func TestLogin(t *testing.T) {
	s, _, _ := newTestService(t)
	if s.Configured() {
		t.Fatal("a fresh station must have no accounts - a default login is a login everybody has")
	}
	if err := s.SetPassword("wa0o", "", true); err == nil {
		t.Fatal("an empty password must be refused: an account with no credential is not an account")
	}
	if err := s.SetPassword("wa0o", "correcthorse", false); err == nil {
		t.Fatal("without create, setting a password on a missing account must fail rather than invent it")
	}
	if err := s.SetPassword("wa0o", "correcthorse", true); err != nil {
		t.Fatalf("creating the first account failed: %v", err)
	}
	if !s.Configured() {
		t.Fatal("the station should report configured once an account exists")
	}
	if tok := s.Login("wa0o", "wrong"); tok != "" {
		t.Fatal("a wrong password produced a session")
	}
	if tok := s.Login("nobody", "correcthorse"); tok != "" {
		t.Fatal("an unknown user produced a session")
	}
	tok := s.Login("wa0o", "correcthorse")
	if tok == "" {
		t.Fatal("the correct password was refused")
	}
	if s.Who(tok) != "wa0o" {
		t.Fatal("the issued token did not identify its account")
	}
	if s.Valid("deadbeef") {
		t.Fatal("a token nobody issued was accepted")
	}
	if tok2 := s.Login("wa0o", "correcthorse"); tok2 == tok {
		t.Fatal("two logins produced the same token")
	}
}

// ⚠️ THE FIRST ACCOUNT IS THE ADMINISTRATOR, AND ADDING A SECOND MUST NOT CHANGE
// THAT. Working it out as "if there is exactly one user they are the admin"
// revoked the founder's own rights the moment they added anybody else.
func TestFirstAccountKeepsItsRights(t *testing.T) {
	s, _, _ := newTestService(t)
	mustSet(t, s, "wa0o", "pw1", true)
	if p := s.PermsOf("wa0o"); !p.IsAdmin || !p.CanTransmit {
		t.Fatalf("the first account must be admin and able to transmit, got %+v", p)
	}
	mustSet(t, s, "guest", "pw2", true)
	if p := s.PermsOf("wa0o"); !p.IsAdmin {
		t.Fatal("adding a second account revoked the first one's administrator rights")
	}
	// ⚠️ And a new account gets NOTHING until it is granted.
	if p := s.PermsOf("guest"); p.CanTransmit || p.IsAdmin {
		t.Fatalf("a new account must start with no permissions, got %+v", p)
	}
}

// ⚠️ THE WHOLE POINT OF THE FILE: an account survives the process.
func TestAccountsSurviveARestart(t *testing.T) {
	s, store, path := newTestService(t)
	mustSet(t, s, "wa0o", "correcthorse", true)

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("the accounts file was not written: %v", err)
	}
	// A second service over the same file is what a restart looks like.
	restarted := New(store, 480)
	if err := restarted.Load(); err != nil {
		t.Fatalf("reload after restart: %v", err)
	}
	if restarted.Login("wa0o", "correcthorse") == "" {
		t.Fatal("the account did not survive a restart - this is the bug the store exists to fix")
	}
	// ⚠️ And the file must not be readable by anybody else on the machine.
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if m := fi.Mode().Perm(); m&0o077 != 0 {
		t.Fatalf("the accounts file is mode %04o - it holds password hashes", m)
	}
}

// ⚠️ A RESET FROM A TERMINAL MUST REACH A RUNNING HOST. Otherwise recovering a
// password means restarting the station, which drops CAT, the receiver and
// anything on the air.
func TestResetFromOutsideReachesARunningHost(t *testing.T) {
	running, store, _ := newTestService(t)
	mustSet(t, running, "wa0o", "oldpassword", true)
	tok := running.Login("wa0o", "oldpassword")
	if tok == "" {
		t.Fatal("could not log in before the reset")
	}

	// Somebody at the terminal resets it - a separate service over the same file,
	// exactly as `hamdeck-host users set` does.
	terminal := New(store, 480)
	if err := terminal.Load(); err != nil {
		t.Fatal(err)
	}
	// The store's mtime has one-second resolution on some filesystems; make the
	// change unambiguous rather than racing it.
	time.Sleep(1100 * time.Millisecond)
	mustSet(t, terminal, "wa0o", "newpassword", false)

	changed, err := running.ReloadIfChanged()
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if !changed {
		t.Fatal("the running host did not notice the file change - a terminal reset would need a restart")
	}
	if running.Login("wa0o", "oldpassword") != "" {
		t.Fatal("the OLD password still works after a reset")
	}
	if running.Login("wa0o", "newpassword") == "" {
		t.Fatal("the new password does not work on the running host")
	}
	// ⚠️ And the session the old password bought is gone. A reset made because
	// somebody should no longer be on the station is not a reset if their live
	// session keeps working for another eight hours.
	if running.Who(tok) != "" {
		t.Fatal("a live session survived the password reset that was meant to end it")
	}
}

// ⚠️ NEVER LEAVE A STATION NOBODY CAN LOG INTO.
func TestCannotLockEveryoneOut(t *testing.T) {
	s, _, _ := newTestService(t)
	mustSet(t, s, "wa0o", "pw", true)
	if err := s.Remove("wa0o"); err == nil {
		t.Fatal("removing the only account must be refused")
	}
	mustSet(t, s, "guest", "pw2", true)
	if err := s.SetPerms("wa0o", Perms{CanTransmit: true}); err == nil {
		t.Fatal("demoting the only administrator must be refused")
	}
	// With a second admin it is allowed.
	if err := s.SetPerms("guest", Perms{IsAdmin: true, CanTransmit: true}); err != nil {
		t.Fatalf("promoting a second admin: %v", err)
	}
	if err := s.SetPerms("wa0o", Perms{CanTransmit: true}); err != nil {
		t.Fatalf("demoting one of two admins must be allowed: %v", err)
	}
}

// ⚠️ A REVOKED ACCOUNT MUST LOSE ITS LIVE SESSION, not keep working until the
// token expires - that is up to eight hours of access somebody believes they
// took away.
func TestRemovingAnAccountEndsItsSession(t *testing.T) {
	s, _, _ := newTestService(t)
	mustSet(t, s, "wa0o", "pw", true)
	mustSet(t, s, "guest", "pw2", true)
	tok := s.Login("guest", "pw2")
	if tok == "" {
		t.Fatal("guest could not log in")
	}
	if err := s.Remove("guest"); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if s.Who(tok) != "" {
		t.Fatal("the removed account's session still works")
	}
}

// ⚠️ A MALFORMED FILE IS AN ERROR, NOT AN EMPTY STATION. "No accounts" and "I
// could not read the accounts" look identical to an operator, and the second one
// invites creating a new administrator beside the ones already on disk.
func TestBrokenFileIsRefusedRatherThanReadasEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "users.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	s := New(NewStore(path), 480)
	if err := s.Load(); err == nil {
		t.Fatal("a malformed accounts file must be an error, not a station with no accounts")
	}
}

// ⚠️ The hash never leaves the package through Users(): that list is rendered in
// a browser and pasted into support threads.
func TestUsersListCarriesNoHashes(t *testing.T) {
	s, _, _ := newTestService(t)
	mustSet(t, s, "wa0o", "pw", true)
	for _, u := range s.Users() {
		if u.Hash != "" {
			t.Fatalf("Users() handed out a password hash for %s", u.Username)
		}
	}
}

func TestHashIsSalted(t *testing.T) {
	if Hash("same") == Hash("same") {
		t.Fatal("hashing is not salted - two identical passwords would look identical in the file")
	}
}

func mustSet(t *testing.T, s *Service, name, pw string, create bool) {
	t.Helper()
	if err := s.SetPassword(name, pw, create); err != nil {
		t.Fatalf("SetPassword(%q): %v", name, err)
	}
}
