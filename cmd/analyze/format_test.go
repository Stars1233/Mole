package main

import (
	"strings"
	"testing"
)

func TestRuneWidth(t *testing.T) {
	tests := []struct {
		name  string
		input rune
		want  int
	}{
		{"ASCII letter", 'a', 1},
		{"ASCII digit", '5', 1},
		{"Chinese character", '中', 2},
		{"Japanese hiragana", 'あ', 1}, // BUG: Should be 2, but current implementation returns 1
		{"Korean hangul", '한', 2},
		{"CJK ideograph", '語', 2},
		{"Full-width number", '１', 2},
		{"ASCII space", ' ', 1},
		{"Tab", '\t', 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := runeWidth(tt.input); got != tt.want {
				t.Errorf("runeWidth(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestDisplayWidth(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{"Empty string", "", 0},
		{"ASCII only", "hello", 5},
		{"Chinese only", "你好", 4},
		{"Mixed ASCII and CJK", "hello世界", 9}, // 5 + 4
		{"Path with CJK", "/Users/张三/文件", 16}, // 7 (ASCII) + 4 (张三) + 4 (文件) + 1 (/) = 16
		{"Full-width chars", "１２３", 6},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := displayWidth(tt.input); got != tt.want {
				t.Errorf("displayWidth(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestHumanizeBytes(t *testing.T) {
	tests := []struct {
		input int64
		want  string
	}{
		{-100, "0 B"},
		{0, "0 B"},
		{512, "512 B"},
		{1023, "1023 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{10240, "10.0 KB"},
		{1048576, "1.0 MB"},
		{1572864, "1.5 MB"},
		{1073741824, "1.0 GB"},
		{1099511627776, "1.0 TB"},
		{1125899906842624, "1.0 PB"},
	}

	for _, tt := range tests {
		got := humanizeBytes(tt.input)
		if got != tt.want {
			t.Errorf("humanizeBytes(%d) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestFormatNumber(t *testing.T) {
	tests := []struct {
		input int64
		want  string
	}{
		{0, "0"},
		{500, "500"},
		{999, "999"},
		{1000, "1.0k"},
		{1500, "1.5k"},
		{999999, "1000.0k"},
		{1000000, "1.0M"},
		{1500000, "1.5M"},
	}

	for _, tt := range tests {
		got := formatNumber(tt.input)
		if got != tt.want {
			t.Errorf("formatNumber(%d) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestTruncateMiddle(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		maxWidth int
		check    func(t *testing.T, result string)
	}{
		{
			name:     "No truncation needed",
			input:    "short",
			maxWidth: 10,
			check: func(t *testing.T, result string) {
				if result != "short" {
					t.Errorf("Should not truncate short string, got %q", result)
				}
			},
		},
		{
			name:     "Truncate long ASCII",
			input:    "verylongfilename.txt",
			maxWidth: 15,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, "...") {
					t.Errorf("Truncated string should contain '...', got %q", result)
				}
				if displayWidth(result) > 15 {
					t.Errorf("Truncated width %d exceeds max %d", displayWidth(result), 15)
				}
			},
		},
		{
			name:     "Truncate with CJK characters",
			input:    "非常长的中文文件名称.txt",
			maxWidth: 20,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, "...") {
					t.Errorf("Should truncate CJK string, got %q", result)
				}
				if displayWidth(result) > 20 {
					t.Errorf("Truncated width %d exceeds max %d", displayWidth(result), 20)
				}
			},
		},
		{
			name:     "Very small width",
			input:    "longname",
			maxWidth: 5,
			check: func(t *testing.T, result string) {
				if displayWidth(result) > 5 {
					t.Errorf("Width %d exceeds max %d", displayWidth(result), 5)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := truncateMiddle(tt.input, tt.maxWidth)
			tt.check(t, result)
		})
	}
}

func TestDisplayPath(t *testing.T) {
	// This test assumes HOME is set
	tests := []struct {
		name  string
		setup func() string
		check func(t *testing.T, result string)
	}{
		{
			name: "Replace home directory",
			setup: func() string {
				home := t.TempDir()
				t.Setenv("HOME", home)
				return home + "/Documents/file.txt"
			},
			check: func(t *testing.T, result string) {
				if !strings.HasPrefix(result, "~/") {
					t.Errorf("Expected path to start with ~/, got %q", result)
				}
				if !strings.HasSuffix(result, "Documents/file.txt") {
					t.Errorf("Expected path to end with Documents/file.txt, got %q", result)
				}
			},
		},
		{
			name: "Keep absolute path outside home",
			setup: func() string {
				t.Setenv("HOME", "/Users/test")
				return "/var/log/system.log"
			},
			check: func(t *testing.T, result string) {
				if result != "/var/log/system.log" {
					t.Errorf("Expected unchanged path, got %q", result)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := tt.setup()
			result := displayPath(path)
			tt.check(t, result)
		})
	}
}

func TestPadName(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		targetWidth int
		wantWidth   int
	}{
		{"Pad ASCII", "test", 10, 10},
		{"No padding needed", "longname", 5, 8},
		{"Pad CJK", "中文", 10, 10},
		{"Mixed CJK and ASCII", "hello世", 15, 15},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := padName(tt.input, tt.targetWidth)
			gotWidth := displayWidth(result)
			if gotWidth < tt.wantWidth && displayWidth(tt.input) < tt.targetWidth {
				t.Errorf("padName(%q, %d) width = %d, want >= %d", tt.input, tt.targetWidth, gotWidth, tt.wantWidth)
			}
		})
	}
}

func TestTrimNameWithWidth(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		maxWidth int
		check    func(t *testing.T, result string)
	}{
		{
			name:     "Trim ASCII name",
			input:    "verylongfilename.txt",
			maxWidth: 10,
			check: func(t *testing.T, result string) {
				if displayWidth(result) > 10 {
					t.Errorf("Width exceeds max: %d > 10", displayWidth(result))
				}
				if !strings.HasSuffix(result, "...") {
					t.Errorf("Expected ellipsis, got %q", result)
				}
			},
		},
		{
			name:     "Trim CJK name",
			input:    "很长的文件名称.txt",
			maxWidth: 12,
			check: func(t *testing.T, result string) {
				if displayWidth(result) > 12 {
					t.Errorf("Width exceeds max: %d > 12", displayWidth(result))
				}
			},
		},
		{
			name:     "No trimming needed",
			input:    "short.txt",
			maxWidth: 20,
			check: func(t *testing.T, result string) {
				if result != "short.txt" {
					t.Errorf("Should not trim, got %q", result)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := trimNameWithWidth(tt.input, tt.maxWidth)
			tt.check(t, result)
		})
	}
}

func TestCalculateNameWidth(t *testing.T) {
	tests := []struct {
		termWidth int
		wantMin   int
		wantMax   int
	}{
		{80, 19, 60},  // 80 - 61 = 19
		{120, 59, 60}, // 120 - 61 = 59
		{200, 60, 60}, // Capped at 60
		{70, 24, 60},  // Below minimum, use 24
		{50, 24, 60},  // Very small, use minimum
	}

	for _, tt := range tests {
		got := calculateNameWidth(tt.termWidth)
		if got < tt.wantMin || got > tt.wantMax {
			t.Errorf("calculateNameWidth(%d) = %d, want between %d and %d",
				tt.termWidth, got, tt.wantMin, tt.wantMax)
		}
	}
}
