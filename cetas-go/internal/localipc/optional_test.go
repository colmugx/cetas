package localipc

import "testing"

func TestOwnerLeaseEnabledDefaultsToBestEffort(t *testing.T) {
	for _, tc := range []struct {
		value string
		want bool
	}{
		{"", true},
		{"0", false},
		{"false", false},
		{" NO ", false},
		{"off", false},
		{"1", true},
		{"true", true},
		{"yes", true},
		{"broken", true},
	} {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("CETAS_IPC_OWNER", tc.value)
			if got := OwnerLeaseEnabled(); got != tc.want {
				t.Fatalf("CETAS_IPC_OWNER=%q: got %v want %v", tc.value, got, tc.want)
			}
		})
	}
}
