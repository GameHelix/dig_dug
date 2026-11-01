package main

import "testing"

func TestRemaining(t *testing.T) {
	cases := []struct{ tank, burn, want int }{
		{100, 30, 70},
		{50, 80, 0},
		{maxBurn, maxBurn, 0},
	}
	for _, c := range cases {
		if got := remaining(c.tank, c.burn); got != c.want {
			t.Errorf("remaining(%d, %d) = %d, want %d (%s)", c.tank, c.burn, got, c.want, vehicle)
		}
	}
}
