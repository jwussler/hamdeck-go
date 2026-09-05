// Package auth is accounts and sessions.
//
// ⚠️ THE FILE IS THE ACCOUNTS. There is exactly one place an account exists -
// the store, see store.go - and exactly one way to create or reset one:
// `hamdeck-host users set <name>` on the machine. No username in code, no hash
// in an environment variable, no second path that only works on a fresh install.
//
// This was rewritten rather than extended on 09/04/2026. What it replaced kept
// users in one map, their permissions in another, took the only real credential
// from HAMDECK_ADMIN_HASH, and attached it to a username spelled "admin" in
// main.go - so there was no supported way to change the operator's own name, and
// no way at all to reset a forgotten password from a terminal. Three mechanisms
// that had to agree, and a recovery story that was "edit Go and rebuild".
//
// ⚠️ PBKDF2-HMAC-SHA256, 350000 iterations, format pbkdf2:<hex salt>:<hex hash>.
// The same as the C++ host on purpose: a station moves between the two without
// anybody re-enrolling.
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

// Perms is what one account may do.
//
// ⚠️ CAN-TRANSMIT IS THE ONE THAT MATTERS. An account that can listen to a
// receiver is a very different thing from one that can key a transmitter, and a
// model where everyone who can log in can transmit is not a permission model.
type Perms struct {
	CanTransmit bool `json:"can_transmit"`
	IsAdmin     bool `json:"is_admin"`
	IsStation   bool `json:"is_station"`
}

type Service struct {
	mu       sync.RWMutex
	store    *Store
	users    map[string]User
	sessions map[string]session
	ttl      time.Duration
	loadedAt time.Time
}

type session struct {
	user    string
	expires time.Time
}

// New builds the service around a store. Nothing is read until Load.
func New(store *Store, ttlMinutes int) *Service {
	if ttlMinutes <= 0 {
		ttlMinutes = 480
	}
	return &Service{
		store:    store,
		users:    map[string]User{},
		sessions: map[string]session{},
		ttl:      time.Duration(ttlMinutes) * time.Minute,
	}
}

// Load reads the accounts file. A missing file is not an error - it is a station
// nobody has set up yet - but an unreadable or malformed one is.
func (s *Service) Load() error {
	users, err := s.store.Load()
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.replaceLocked(users)
	s.loadedAt = s.store.ModTime()
	return nil
}

// ReloadIfChanged picks up a reset done from a terminal WITHOUT a restart.
//
// ⚠️ THIS IS WHY A LOCKOUT IS NOT AN OUTAGE. Restarting the host to apply a new
// password drops CAT, the receiver and any transmission in progress; an operator
// locked out mid-net would have to take the station down to get back in. The
// file's modification time is enough - accounts change by hand, rarely, and a
// stat every few seconds costs nothing.
func (s *Service) ReloadIfChanged() (bool, error) {
	mt := s.store.ModTime()
	s.mu.RLock()
	same := mt.Equal(s.loadedAt)
	s.mu.RUnlock()
	if same {
		return false, nil
	}
	users, err := s.store.Load()
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.replaceLocked(users)
	s.loadedAt = mt
	return true, nil
}

// replaceLocked swaps the account set and ends sessions that no longer stand.
//
// ⚠️ A CHANGED PASSWORD MUST END THE SESSIONS IT PROTECTED. Resetting a
// credential because somebody should no longer have access, while their live
// session keeps working for another eight hours, is not a reset. Same for a
// deleted account.
func (s *Service) replaceLocked(users []User) {
	next := make(map[string]User, len(users))
	for _, u := range users {
		if u.Username == "" || !strings.HasPrefix(u.Hash, "pbkdf2:") {
			continue // a user with no credential is not a user
		}
		next[u.Username] = u
	}
	for tok, sess := range s.sessions {
		old, had := s.users[sess.user]
		cur, still := next[sess.user]
		if !still || (had && old.Hash != cur.Hash) {
			delete(s.sessions, tok)
		}
	}
	s.users = next
}

// Configured reports whether anybody can log in at all.
func (s *Service) Configured() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.users) > 0
}

// ── The credential ──────────────────────────────────────────────────────────

func Hash(password string) string {
	salt := make([]byte, 16)
	rand.Read(salt)
	dk := pbkdf2.Key([]byte(password), salt, iterations, 32, sha256.New)
	return "pbkdf2:" + hex.EncodeToString(salt) + ":" + hex.EncodeToString(dk)
}

func verify(stored, password string) bool {
	parts := strings.Split(stored, ":")
	if len(parts) != 3 {
		return false
	}
	salt, err := hex.DecodeString(parts[1])
	if err != nil {
		return false
	}
	want, err := hex.DecodeString(parts[2])
	if err != nil {
		return false
	}
	got := pbkdf2.Key([]byte(password), salt, iterations, 32, sha256.New)
	// ⚠️ Constant time. A byte-by-byte compare leaks the hash through timing.
	return subtle.ConstantTimeCompare(got, want) == 1
}

// Login returns a session token, or "".
//
// ⚠️ It says nothing about WHICH half was wrong: "no such user" tells an
// attacker which names exist on the station.
func (s *Service) Login(user, password string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[user]
	if !ok || !verify(u.Hash, password) {
		return ""
	}
	raw := make([]byte, 24)
	rand.Read(raw)
	tok := hex.EncodeToString(raw)
	s.sessions[tok] = session{user: user, expires: time.Now().Add(s.ttl)}
	return tok
}

// ── Sessions ────────────────────────────────────────────────────────────────

func (s *Service) Valid(token string) bool { return s.Who(token) != "" }

func (s *Service) Who(token string) string {
	if token == "" {
		return ""
	}
	s.mu.RLock()
	sess, ok := s.sessions[token]
	s.mu.RUnlock()
	if !ok {
		return ""
	}
	if time.Now().After(sess.expires) {
		s.mu.Lock()
		delete(s.sessions, token)
		s.mu.Unlock()
		return ""
	}
	return sess.user
}

// Logout reports whether a session was really ended. ⚠️ Answering "ok" for a
// token that was already gone tells an operator they logged out of something
// when nothing happened.
func (s *Service) Logout(token string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, existed := s.sessions[token]
	delete(s.sessions, token)
	return existed
}

// SessionInfo is one live session, for the admin page.
//
// ⚠️ NO TOKENS. A list of live sessions carrying their tokens is a list of
// working credentials, rendered in a browser and pasted into support threads.
// The id is a short prefix: enough to tell two apart, useless to log in with.
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
			ID: tok[:8], User: sess.user,
			Expires: sess.expires.Format("01/02/2006 15:04"),
			Minutes: int(sess.expires.Sub(now).Minutes()),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].User < out[j].User })
	return out
}

// Kick ends every session whose id starts with the given prefix.
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

// ── Accounts. Every one of these writes the file. ───────────────────────────

// Users is the account list, without hashes.
func (s *Service) Users() []User {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]User, 0, len(s.users))
	for _, u := range s.users {
		u.Hash = "" // ⚠️ never hand a hash to a caller that is going to render it
		out = append(out, u)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Username < out[j].Username })
	return out
}

func (s *Service) Exists(name string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.users[name]
	return ok
}

// SetPassword sets or resets one account's password, creating it if asked.
//
// ⚠️ CREATING IS A SEPARATE DECISION, PASSED IN. "Change the password" quietly
// creating an account that was never meant to exist is how a typo becomes a
// login; but the terminal reset path legitimately needs to create the first one,
// so the caller says which it means rather than the rule being guessed here.
//
// ⚠️ THE FIRST ACCOUNT ON A STATION IS ITS ADMINISTRATOR, and that is RECORDED,
// not inferred. Working it out on the fly as "if there is exactly one user they
// are the admin" quietly revoked the founder's own rights the moment they added
// a second account, locking them out of the page they were standing on.
func (s *Service) SetPassword(name, password string, create bool) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("a username is required")
	}
	if password == "" {
		// ⚠️ Refused, never hashed. A blank credential that hashes fine is an
		// account anybody can log into.
		return fmt.Errorf("an empty password is not a password")
	}
	s.mu.Lock()
	u, exists := s.users[name]
	if !exists {
		if !create {
			return unlockErr(&s.mu, fmt.Errorf("there is no account called %q", name))
		}
		u = User{Username: name}
		if len(s.users) == 0 {
			u.CanTransmit, u.IsAdmin = true, true
		}
	}
	u.Hash = Hash(password)
	s.users[name] = u
	// ⚠️ A password change ends that account's sessions. Otherwise a reset made
	// because somebody should no longer be on the station leaves them on it.
	for tok, sess := range s.sessions {
		if sess.user == name {
			delete(s.sessions, tok)
		}
	}
	users := s.snapshotLocked()
	s.mu.Unlock()
	return s.persist(users)
}

// Remove deletes an account and ends its sessions.
//
// ⚠️ BOTH HALVES, ALWAYS. Removing the account and leaving the session alive
// means a revoked user keeps working until their token expires - up to eight
// hours of access somebody believes they took away.
func (s *Service) Remove(name string) error {
	s.mu.Lock()
	if _, ok := s.users[name]; !ok {
		return unlockErr(&s.mu, fmt.Errorf("there is no account called %q", name))
	}
	if len(s.users) == 1 {
		// ⚠️ Never the last one. A station with no accounts cannot be logged
		// into, and the panel cannot be used to fix it.
		return unlockErr(&s.mu, fmt.Errorf(
			"%q is the only account - removing it would lock everyone out", name))
	}
	delete(s.users, name)
	for tok, sess := range s.sessions {
		if sess.user == name {
			delete(s.sessions, tok)
		}
	}
	users := s.snapshotLocked()
	s.mu.Unlock()
	return s.persist(users)
}

// SetPerms records what an account may do.
func (s *Service) SetPerms(name string, p Perms) error {
	s.mu.Lock()
	u, ok := s.users[name]
	if !ok {
		return unlockErr(&s.mu, fmt.Errorf("there is no account called %q", name))
	}
	if u.IsAdmin && !p.IsAdmin && s.lastAdminLocked(name) {
		// ⚠️ The last administrator cannot be demoted. A station whose only
		// admin has been demoted needs a terminal to fix, and the person doing
		// the demoting is usually the person who then cannot undo it.
		return unlockErr(&s.mu, fmt.Errorf(
			"%q is the only administrator - promote somebody else first", name))
	}
	u.CanTransmit, u.IsAdmin, u.IsStation = p.CanTransmit, p.IsAdmin, p.IsStation
	s.users[name] = u
	users := s.snapshotLocked()
	s.mu.Unlock()
	return s.persist(users)
}

func (s *Service) lastAdminLocked(name string) bool {
	for n, u := range s.users {
		if n != name && u.IsAdmin {
			return false
		}
	}
	return true
}

// PermsOf answers for a username. ⚠️ An unknown account gets NOTHING, not
// everything: a permission lookup that fails open is worse than no permissions.
func (s *Service) PermsOf(name string) Perms {
	s.mu.RLock()
	defer s.mu.RUnlock()
	u, ok := s.users[name]
	if !ok {
		return Perms{}
	}
	return Perms{CanTransmit: u.CanTransmit, IsAdmin: u.IsAdmin, IsStation: u.IsStation}
}

func (s *Service) CanTransmit(token string) bool { return s.PermsOf(s.Who(token)).CanTransmit }
func (s *Service) IsAdmin(token string) bool     { return s.PermsOf(s.Who(token)).IsAdmin }

func (s *Service) snapshotLocked() []User {
	out := make([]User, 0, len(s.users))
	for _, u := range s.users {
		out = append(out, u)
	}
	return out
}

// persist writes the file and remembers when, so the reload check does not
// immediately re-read what this process just wrote.
func (s *Service) persist(users []User) error {
	if err := s.store.Save(users); err != nil {
		return err
	}
	s.mu.Lock()
	s.loadedAt = s.store.ModTime()
	s.mu.Unlock()
	return nil
}

func unlockErr(mu *sync.RWMutex, err error) error {
	mu.Unlock()
	return err
}
