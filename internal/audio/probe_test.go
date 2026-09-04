package audio

import "testing"

// ⚠️ THIS TEST CANNOT OPEN A SOUND CARD, AND SAYS SO RATHER THAN PASSING QUIETLY.
//
// CI runners have no audio hardware, so the useful assertion here is not "audio
// arrived" - it is that the code reports the ABSENCE of a device as an error
// instead of returning a zero peak that reads exactly like silence from a
// working card. That distinction is the whole reason this package exists: on
// 09/04/2026 nothing in the older C++ host could tell a live band from a dead
// one on receive, and "it read frames" was the evidence being relied on.
//
// The real proof is on the station: `hamdeck-host --audio-probe codec` against
// the radio, which reported 7741/32767. A machine with no card cannot repeat it.
func TestProbeReportsMissingDeviceRatherThanSilence(t *testing.T) {
	desc, peak, err := Probe("no-such-card-anywhere", 0)
	if err == nil {
		t.Fatalf("a missing device must be an error, not %d peak on %q", peak, desc)
	}
	if peak != 0 {
		t.Fatalf("a failed probe must not report a level, got %d", peak)
	}
}

// ⚠️ Listing must not explode where there is no /dev/snd at all - a host that
// refuses to start on a machine with no sound card cannot even be inspected.
func TestListIsSafeWithoutHardware(t *testing.T) {
	if _, err := List(); err != nil {
		t.Logf("no sound devices here, which is expected on CI: %v", err)
	}
}
