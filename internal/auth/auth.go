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
