package main

import (
	"strings"
	"testing"
)

func TestCopyHistoryReadsSourceWithoutRendering(t *testing.T) {
	m:=newModel()
	m.transcript=[]string{"> 你好","rendered placeholder","• bash","hidden"}
	m.markdownRaw=map[int]string{1:"**original** Markdown"}
	text,err:=m.copyTranscriptSource(1,3)
	if err!=nil {t.Fatal(err)}
	if text!="> 你好\n\n**original** Markdown\n\n• bash" {
		t.Fatalf("copy lost source or changed order: %q",text)
	}
	if m.virtualScroll!=nil&&m.virtualScroll.renderedBlocks!=0 {
		t.Fatal("copy rendered offscreen blocks")
	}
}

func TestCopyHistoryRejectsInvalidAndOversizedRanges(t *testing.T) {
	m:=newModel()
	m.transcript=[]string{"hello",strings.Repeat("x",maxTranscriptCopyChars+1)}
	for _,rangePair:=range [][2]int{{0,1},{2,1},{1,3},{-1,0}} {
		if _,err:=m.copyTranscriptSource(rangePair[0],rangePair[1]);err==nil {
			t.Fatalf("invalid range passed: %#v",rangePair)
		}
	}
	if _,err:=m.copyTranscriptSource(1,2);err==nil {
		t.Fatal("oversized source copy accepted")
	}
	if _,err:=m.copyHistoryCommand([]string{"/copyhistory","one"});err==nil {
		t.Fatal("malformed copy command accepted")
	}
	if _,err:=m.copyHistoryCommand([]string{"/copyhistory","1","nope"});err==nil {
		t.Fatal("malformed end index accepted")
	}
}

func TestCopyHistorySlashCommandDoesNotDispatchHost(t *testing.T) {
	m:=newModel()
	m.transcript=[]string{"one","two"}
	cmd:=m.command("/copyhistory 1 2")
	if cmd==nil || !strings.Contains(m.status,"sent transcript") {
		t.Fatalf("copy did not dispatch OSC52 clipboard: status=%q",m.status)
	}
	if len(slashSuggestions("/copyhistory"))==0 {t.Fatal("copyhistory missing from slash registry")}
}
