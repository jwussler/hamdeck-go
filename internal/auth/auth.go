// Package auth: sessions and the credential.
//
// ⚠️ SAME KDF AND THE SAME FORMAT AS THE C++ HOST - pbkdf2:<hex salt>:<hex hash>,
// PBKDF2-HMAC-SHA256, 350000 iterations. Not for compatibility's sake: it means a
// station can move between the two hosts without every operator re-enrolling, and
// it means this experiment can be judged on the thing being tested rather than on
// a login that behaves differently.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/pbkdf2"
)

const iterations = 350000

type Service struct {
	mu       sync.RWMutex
	users    map[string]string // username -> hash
	sessions map[string]session
	ttl      time.Duration
}

type session struct {
	user    string
	expires time.Time
}

func New(ttlMinutes int) *Service {
	if ttlMinutes <= 0 {
		ttlMinutes = 480
	}
	return &Service{
		users:    map[string]string{},
		sessions: map[string]session{},
		ttl:      time.Duration(ttlMinutes) * time.Minute,
	}
}

func Hash(password string) string {
	salt := make([]byte, 16)
	rand.Read(salt)
	dk := pbkdf2.Key([]byte(password), salt, iterations, 32, sha256.New)
	return "pbkdf2:" + hex.EncodeToString(salt) + ":" + hex.EncodeToString(dk)
}

func (s *Service) AddUser(name, hash string) error {
	// ⚠️ An empty hash is REFUSED, not stored. The C++ host shipped an example
	// config with a blank placeholder hash and a fresh install sat in a restart
	// loop; a user with no credential is not a user.
	if name == "" || !strings.HasPrefix(hash, "pbkdf2:") {
		return fmt.Errorf("user %q needs a pbkdf2: hash", name)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.users[name] = hash
	return nil
}

func (s *Service) Configured() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.users) > 0
}

// Login returns a session token, or "" - and deliberately says nothing about
// WHICH half was wrong. "No such user" tells an attacker which names exist.
func (s *Service) Login(user, password string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, ok := s.users[user]
	if !ok {
		return ""
	}
	parts := strings.Split(stored, ":")
	if len(parts) != 3 {
		return ""
	}
	salt, err := hex.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	want, err := hex.DecodeString(parts[2])
	if err != nil {
		return ""
	}
	got := pbkdf2.Key([]byte(password), salt, iterations, 32, sha256.New)
	// ⚠️ Constant time. A byte-by-byte compare leaks the hash through timing.
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ""
	}
	raw := make([]byte, 24)
	rand.Read(raw)
	tok := hex.EncodeToString(raw)
	s.sessions[tok] = session{user: user, expires: time.Now().Add(s.ttl)}
	return tok
}

func (s *Service) Valid(token string) bool {
	s.mu.RLock()
	sess, ok := s.sessions[token]
	s.mu.RUnlock()
	if !ok {
		return false
	}
	if time.Now().After(sess.expires) {
		s.mu.Lock()
		delete(s.sessions, token)
		s.mu.Unlock()
		return false
	}
	return true
}

// ── Session and user management ─────────────────────────────────────────────

// Who returns the username behind a token, or "" if it is not a live session.
func (s *Service) Who(token string) string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[token]
	if !ok || time.Now().After(sess.expires) {
		return ""
	}
	return sess.user
}

// Logout ends one session. ⚠️ It reports whether a session was actually ended:
// "ok" for a token that was already gone tells an operator their session was
// closed when nothing happened.
func (s *Service) Logout(token string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, existed := s.sessions[token]
	delete(s.sessions, token)
	return existed
}

// SessionInfo is one live session, for the admin page.
//
// ⚠️ NO TOKENS. A list of live sessions that carries the tokens is a list of
// working credentials, and it would be rendered in a browser and copied into
// support conversations. The id is a short prefix, enough to tell two sessions
// apart and useless for logging in.
type SessionInfo struct {
	ID      string `json:"id"`
	User    string `json:"user"`
	Expires string `json:"expires"`
	Minutes int    `json:"minutes_left"`
}

func (s *Service) Sessions() []SessionInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []SessionInfo{}
	now := time.Now()
	for tok, sess := range s.sessions {
		if now.After(sess.expires) {
			continue
		}
		out = append(out, SessionInfo{
			ID:      tok[:8],
			User:    sess.user,
			Expires: sess.expires.Format("01/02/2006 15:04"),
			Minutes: int(sess.expires.Sub(now).Minutes()),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].User < out[j].User })
	return out
}

// Kick ends every session whose id prefix matches. Returns how many went.
func (s *Service) Kick(idPrefix string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for tok := range s.sessions {
		if strings.HasPrefix(tok, idPrefix) {
			delete(s.sessions, tok)
			n++
		}
	}
	return n
}

func (s *Service) Users() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]string, 0, len(s.users))
	for u := range s.users {
		out = append(out, u)
	}
	sort.Strings(out)
	return out
}

// SetPassword changes an existing user's password.
//
// ⚠️ IT REFUSES TO CREATE ONE. "Change the password" quietly adding an account
// that was never meant to exist is how a typo becomes a login.
func (s *Service) SetPassword(name, hash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.users[name]; !ok {
		return fmt.Errorf("there is no user called %q", name)
	}
	s.users[name] = hash
	return nil
}

// RemoveUser deletes a user and ends their sessions.
//
// ⚠️ BOTH HALVES, ALWAYS. Removing the account and leaving the session alive
// means a revoked user keeps working until their token expires - which is up to
// eight hours of access that somebody believes they took away.
func (s *Service) RemoveUser(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.users[name]; !ok {
		return fmt.Errorf("there is no user called %q", name)
	}
	if len(s.users) == 1 {
		// ⚠️ Never remove the last one. A host with no users cannot be logged
		// into and cannot be fixed from the panel.
		return fmt.Errorf("%q is the only user - removing it would lock everyone out", name)
	}
	delete(s.users, name)
	for tok, sess := range s.sessions {
		if sess.user == name {
			delete(s.sessions, tok)
		}
	}
	return nil
}
