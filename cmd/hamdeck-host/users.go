package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/jwussler/hamdeck-go/internal/auth"
)

// The account commands: the way back into a station, from a terminal.
//
// ⚠️ THIS IS THE RECOVERY PATH, AND IT IS PART OF THE PRODUCT. Whoever can reach
// the machine can fix the login with the binary that is already installed - no
// panel, no session, no network, nothing to download. Before this existed the
// only credential came from an environment variable attached to a username
// written into Go, so a forgotten password meant editing source and rebuilding.
//
// ⚠️ NO PASSWORD ON THE COMMAND LINE, EVER, and there is deliberately no flag for
// one. Arguments are in the shell history and visible in `ps` to every user on
// the box. It is prompted with the echo off, or read from stdin when this is
// being scripted - and when it comes from stdin it SAYS so, because a password
// that scrolled past unnoticed is one nobody knows they have to rotate.
//
//	hamdeck-host users list
//	hamdeck-host users set <name>          # create or reset, prompts twice
//	hamdeck-host users remove <name>
//	hamdeck-host users grant  <name> tx|admin|station
//	hamdeck-host users revoke <name> tx|admin|station
//
// The running host notices the change within a few seconds - see
// Service.ReloadIfChanged - so a reset does not mean restarting the station and
// dropping CAT, the receiver and anything on the air.
func usersCommand(store *auth.Store, args []string) int {
	svc := auth.New(store, 0)
	if err := svc.Load(); err != nil {
		fmt.Fprintf(os.Stderr, "FATAL: %v\n", err)
		return 1
	}
	for _, w := range store.Warnings() {
		fmt.Fprintf(os.Stderr, "⚠️  %s\n", w)
	}

	if len(args) == 0 {
		usersUsage()
		return 2
	}
	switch args[0] {
	case "list":
		return usersList(svc, store)
	case "set":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: hamdeck-host users set <username>")
			return 2
		}
		return usersSet(svc, store, args[1])
	case "remove":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: hamdeck-host users remove <username>")
			return 2
		}
		if err := svc.Remove(args[1]); err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			return 1
		}
		fmt.Printf("removed %s, and ended its sessions\n", args[1])
		return 0
	case "grant", "revoke":
		if len(args) != 3 {
			fmt.Fprintf(os.Stderr, "usage: hamdeck-host users %s <username> tx|admin|station\n", args[0])
			return 2
		}
		return usersPerm(svc, args[1], args[2], args[0] == "grant")
	}
	usersUsage()
	return 2
}

func usersUsage() {
	fmt.Fprint(os.Stderr, `manage the accounts on this station

  hamdeck-host users list
  hamdeck-host users set <username>              create an account, or reset its password
  hamdeck-host users remove <username>
  hamdeck-host users grant  <username> tx|admin|station
  hamdeck-host users revoke <username> tx|admin|station

The password is prompted for, never taken as an argument - an argument is in your
shell history and visible in ps to everyone on this machine.

Use --users <path> to work on a store other than the default.
`)
}

func usersList(svc *auth.Service, store *auth.Store) int {
	users := svc.Users()
	if len(users) == 0 {
		// ⚠️ Say what to do about it. "No accounts" on a station somebody is
		// locked out of is a dead end unless the next line is the way back in.
		fmt.Printf("no accounts in %s\n\n", store.Path())
		fmt.Printf("create the first one with:  hamdeck-host users set <username>\n")
		fmt.Printf("it will be the administrator and will be allowed to transmit.\n")
		return 0
	}
	fmt.Printf("%s\n\n", store.Path())
	fmt.Printf("%-20s %-9s %-6s %s\n", "USERNAME", "TRANSMIT", "ADMIN", "STATION")
	for _, u := range users {
		fmt.Printf("%-20s %-9s %-6s %s\n", u.Username,
			yesNo(u.CanTransmit), yesNo(u.IsAdmin), yesNo(u.IsStation))
	}
	return 0
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func usersSet(svc *auth.Service, store *auth.Store, name string) int {
	existed := svc.Exists(name)
	pw, err := readPassword(existed)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}
	if err := svc.SetPassword(name, pw, true); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}
	if existed {
		fmt.Printf("password reset for %s, and its live sessions were ended.\n", name)
	} else {
		fmt.Printf("created %s in %s\n", name, store.Path())
		p := svc.PermsOf(name)
		if p.IsAdmin {
			fmt.Printf("it is the first account, so it is the administrator and may transmit.\n")
		} else {
			// ⚠️ A new account starts with nothing. Say it, or the operator
			// discovers it when the person cannot key up mid-net.
			fmt.Printf("⚠️  it may listen but NOT transmit. Grant that with:\n")
			fmt.Printf("      hamdeck-host users grant %s tx\n", name)
		}
	}
	fmt.Printf("the running host picks this up within a few seconds - no restart.\n")
	return 0
}

func usersPerm(svc *auth.Service, name, what string, on bool) int {
	p := svc.PermsOf(name)
	if !svc.Exists(name) {
		fmt.Fprintf(os.Stderr, "there is no account called %q\n", name)
		return 1
	}
	switch what {
	case "tx", "transmit":
		p.CanTransmit = on
	case "admin":
		p.IsAdmin = on
	case "station":
		p.IsStation = on
	default:
		fmt.Fprintf(os.Stderr, "unknown permission %q - use tx, admin or station\n", what)
		return 2
	}
	if err := svc.SetPerms(name, p); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 1
	}
	fmt.Printf("%s: transmit=%s admin=%s station=%s\n", name,
		yesNo(p.CanTransmit), yesNo(p.IsAdmin), yesNo(p.IsStation))
	return 0
}

// readPassword asks twice, with the echo off.
//
// ⚠️ TWICE, BECAUSE NOTHING ELSE CAN CATCH A TYPO. The password is never shown
// and never stored in the clear, so a mistyped one is simply a station nobody can
// log into - and the person who typed it is the person locked out.
func readPassword(existing bool) (string, error) {
	what := "New password"
	if existing {
		what = "New password (this replaces the current one)"
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		// Scripted. ⚠️ Announce it: a password piped in came from somewhere, and
		// that somewhere - a file, a history entry, a CI log - still has it.
		fmt.Fprintln(os.Stderr, "⚠️  reading the password from stdin, not a terminal.")
		fmt.Fprintln(os.Stderr, "⚠️  whatever fed it still holds it - rotate it if that is a file or a shell history.")
		line, err := bufio.NewReader(os.Stdin).ReadString('\n')
		if err != nil && line == "" {
			return "", fmt.Errorf("no password on stdin")
		}
		pw := strings.TrimRight(line, "\r\n")
		if pw == "" {
			return "", fmt.Errorf("an empty password is not a password")
		}
		return pw, nil
	}
	fmt.Fprintf(os.Stderr, "%s: ", what)
	first, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", err
	}
	fmt.Fprint(os.Stderr, "Again: ")
	second, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", err
	}
	if string(first) != string(second) {
		return "", fmt.Errorf("they do not match - nothing was changed")
	}
	if strings.TrimSpace(string(first)) == "" {
		return "", fmt.Errorf("an empty password is not a password")
	}
	return string(first), nil
}
