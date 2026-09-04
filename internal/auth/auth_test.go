package auth

import "testing"

// ⚠️ THE ASSERTIONS THAT MATTER ARE THE NEGATIVE ONES. That a correct password
// works is the easy half; what actually protects a transmitter is that a wrong
// one does not, that an unknown user is refused the same way as a wrong password,
// and that a token nobody issued is not a session.
func TestLogin(t *testing.T) {
	s := New(480)
	if s.Configured() {
		t.Fatal("a fresh service must have no users - a default login is a login everybody has")
	}
	if err := s.AddUser("admin", ""); err == nil {
		t.Fatal("an empty hash must be refused: a user with no credential is not a user")
	}
	if err := s.AddUser("admin", "plaintext"); err == nil {
		t.Fatal("a non-pbkdf2 hash must be refused rather than stored")
	}
	if err := s.AddUser("admin", Hash("correcthorse")); err != nil {
		t.Fatalf("valid user rejected: %v", err)
	}
	if !s.Configured() {
		t.Fatal("service should report configured once a user exists")
	}

	if tok := s.Login("admin", "wrong"); tok != "" {
		t.Fatal("a wrong password produced a session")
	}
	if tok := s.Login("nobody", "correcthorse"); tok != "" {
		t.Fatal("an unknown user produced a session")
	}
	tok := s.Login("admin", "correcthorse")
	if tok == "" {
		t.Fatal("the correct password was refused")
	}
	if !s.Valid(tok) {
		t.Fatal("the issued token was not accepted")
	}
	if s.Valid("deadbeef") {
		t.Fatal("a token nobody issued was accepted")
	}
	// Two logins must not collide: a shared token would make one operator's
	// session another's.
	if tok2 := s.Login("admin", "correcthorse"); tok2 == tok {
		t.Fatal("two logins produced the same token")
	}
}

// ⚠️ The same password must not produce the same hash twice: a fixed salt makes
// two identical passwords visibly identical in a config file.
func TestHashIsSalted(t *testing.T) {
	if Hash("same") == Hash("same") {
		t.Fatal("hashing is not salted")
	}
}
