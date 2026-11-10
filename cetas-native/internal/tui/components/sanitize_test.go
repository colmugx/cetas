package components

import "testing"

func TestSanitizeSGR(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain text passes", "ls: no such file", "ls: no such file"},
		{"newlines and tabs pass", "a\n\tb", "a\n\tb"},
		{"legit SGR passes", "\x1b[31mred\x1b[0m reset", "\x1b[31mred\x1b[0m reset"},
		{"bare SGR reset passes", "\x1b[m", "\x1b[m"},
		{"truecolor SGR passes", "\x1b[38;2;1;2;3m", "\x1b[38;2;1;2;3m"},
		{"OSC 8 hyperlink dropped", "click \x1b]8;;http://evil.example\x1b\\here\x1b]8;;\x1b\\!", "click here!"},
		{"OSC BEL-terminated dropped", "\x1b]0;stolen title\x07after", "after"},
		{"OSC 52 clipboard dropped", "\x1b]52;c;AAAA\x07", ""},
		{"kitty graphics dropped", "pre\x1b_Ga=d,q=2;AAAA\x1b\\post", "prepost"},
		{"DCS dropped", "\x1bP1$r\x1b\\ok", "ok"},
		{"screen clear dropped", "x\x1b[2Jy", "xy"},
		{"cursor move dropped", "x\x1b[5;10Hy", "xy"},
		{"two-byte escape dropped", "a\x1bMb", "ab"},
		{"C0 controls become spaces", "a\x00\x01\x08\x7fb", "a    b"},
		{"CR becomes space", "a\rb", "a b"},
		{"truncated CSI dropped", "tail\x1b[31", "tail"},
		{"truncated OSC dropped", "tail\x1b]8;http", "tail"},
		{"CSI with intermediates non-SGR dropped", "\x1b[?25lx", "x"},
		{"multibyte UTF-8 passes", "你好 \U0001F600", "你好 \U0001F600"},
	}
	for _, tc := range cases {
		if got := SanitizeSGR(tc.in); got != tc.want {
			t.Errorf("%s: SanitizeSGR(%q) = %q, want %q", tc.name, tc.in, got, tc.want)
		}
	}
}
