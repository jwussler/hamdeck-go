package rig

import "fmt"

// Meter calibration, ported from the C++ host's rig_cal.
//
// ⚠️ THE RAW NUMBERS ARE NOT PERCENTAGES AND THE SCALES ARE NOT THE SAME. Each
// meter has its own curve and its own idea of full scale; drawing any of them as
// raw/255 is wrong in a different way for each one.
func interp(points [][2]float64, raw int) float64 {
	x := float64(raw)
	if len(points) == 0 {
		return 0
	}
	if x <= points[0][0] {
		return points[0][1]
	}
	for i := 1; i < len(points); i++ {
		if x <= points[i][0] {
			x0, y0 := points[i-1][0], points[i-1][1]
			x1, y1 := points[i][0], points[i][1]
			if x1 == x0 {
				return y1
			}
			return y0 + (y1-y0)*(x-x0)/(x1-x0)
		}
	}
	return points[len(points)-1][1]
}

// SWRRatio converts the raw RM6 reading to an SWR ratio.
// hamlib yaesu_default_swr_cal, from testing on an FT-991.
func SWRRatio(raw int) float64 {
	return interp([][2]float64{{12, 1.0}, {39, 1.35}, {65, 1.5}, {89, 2.0}, {242, 5.0}}, raw)
}

// ALCPercent converts raw RM4. ⚠️ RAW 64 IS FULL SCALE, not 255 - a naive
// raw/255 bar shows ALC at a quarter of what it really is, which is the wrong
// direction to be wrong in on a transmitter.
func ALCPercent(raw int) int {
	return int(interp([][2]float64{{0, 0}, {64, 100}}, raw) + 0.5)
}

// PowerMeterPercent converts raw RM5 to PERCENT OF RATED OUTPUT, not watts.
//
// ⚠️ Hamlib's table maps raw 255 to 100 W, and that table is for a 100 W radio.
// This station's FTDX-101MP is a 200 W radio, so applying it as watts would
// UNDER-REPORT transmit power by half - on the one meter that tells an operator
// whether their amplifier is being driven properly.
func PowerMeterPercent(raw int) int {
	return int(interp([][2]float64{{0, 0}, {148, 50}, {255, 100}}, raw) + 0.5)
}

// ── The S-meter ─────────────────────────────────────────────────────────────

// smeterCal is Hamlib's FTDX101D_STR_CAL, verbatim.
//
// ⚠️ IT IS NOT LINEAR AND S9 IS NOT THE MIDDLE. Raw 160 is S9; the whole top
// third of the raw range is the 60 dB above it. Drawing the raw value as a
// percentage bar puts a genuine S9 at two-thirds scale and an S3 at a fifth,
// which is a meter that lies quietly in both directions.
var smeterCal = [][2]float64{
	{0, -60}, {17, -54}, {25, -48}, {34, -42},
	{51, -36}, {68, -30}, {85, -24}, {102, -18},
	{119, -12}, {136, -6}, {160, 0}, {255, 60},
}

// SMeterDb converts the raw SM0 reading to dB relative to S9.
func SMeterDb(raw int) int { return int(interp(smeterCal, raw)) }

// SUnit is what an operator would say out loud.
func SUnit(db int) string {
	if db >= 0 {
		// Above S9 the scale is dB over S9, rounded to 10 dB - the resolution a
		// signal report actually carries. "S9 plus 20", never "S9 plus 17".
		over := ((db + 5) / 10) * 10
		if over == 0 {
			return "S9"
		}
		return fmt.Sprintf("S9+%d", over)
	}
	s := 9 - ((-db + 3) / 6) // each S-unit is 6 dB below S9
	if s < 0 {
		s = 0
	}
	return fmt.Sprintf("S%d", s)
}
