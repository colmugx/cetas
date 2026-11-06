package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const maxTranscriptCopyChars = 4_000_000

// copyTranscriptSource reads the complete source document, never the mounted
// viewport. Indices are 1-based, matching cetas-js /copyhistory.
func (m *model) copyTranscriptSource(first, last int) (string, error) {
	if first < 1 || last < first || last > len(m.transcript) {
		return "", errors.New("invalid transcript copy range")
	}
	var result strings.Builder
	for index:=first-1; index<last; index++ {
		text:=m.transcript[index]
		if raw,ok:=m.markdownRaw[index];ok {text=raw}
		if text=="" {continue}
		additional:=len(text)
		if result.Len()>0 {additional+=2}
		if result.Len()+additional>maxTranscriptCopyChars {
			return "", errors.New("selected transcript text exceeds 4 MB limit")
		}
		if result.Len()>0 {result.WriteString("\n\n")}
		result.WriteString(text)
	}
	return result.String(),nil
}

func (m *model) copyHistoryCommand(parts []string) (string,error) {
	if len(parts)<2||len(parts)>3 {return "",errors.New("usage: /copyhistory <first> [last] (1-based)")}
	first,err:=strconv.Atoi(parts[1]);if err!=nil {return "",errors.New("invalid first history index")}
	last:=first
	if len(parts)==3 {
		last,err=strconv.Atoi(parts[2]);if err!=nil {return "",errors.New("invalid last history index")}
	}
	text,err:=m.copyTranscriptSource(first,last)
	if err!=nil {return "",err}
	if text=="" {return "",errors.New("selected transcript entries have no text")}
	m.status=fmt.Sprintf("sent transcript entries %d–%d to terminal clipboard",first,last)
	return text,nil
}
