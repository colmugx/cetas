package main

import (
	"reflect"
	"testing"
)

func TestSizeFlags(t *testing.T) {
	for _, tc := range []struct {
		os       string
		expected []string
	}{
		{"linux", []string{"-Os", "-ffunction-sections", "-fdata-sections"}},
		{"darwin", []string{"-Os", "-ffunction-sections", "-fdata-sections"}},
		{"windows", []string{"/O1", "/Gw", "/GL"}},
		{"freebsd", nil},
	} {
		t.Run(tc.os, func(t *testing.T) {
			if got := sizeFlags(tc.os); !reflect.DeepEqual(got, tc.expected) {
				t.Fatalf("flags = %v, want %v", got, tc.expected)
			}
		})
	}
}
