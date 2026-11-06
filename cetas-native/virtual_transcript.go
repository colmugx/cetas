package main

import (
	"math"
	"strings"

	"charm.land/lipgloss/v2"
)

// virtualTranscript is the source-independent row index behind the Bubble Tea
// viewport. A Fenwick tree resolves a logical row in O(log messages). Only
// blocks intersecting the viewport and a small overscan window are mounted.
// Nothing here stores rendered text from offscreen messages.
type virtualTranscript struct {
	width, height int
	top int
	followEnd bool
	heights []int
	bit []int // 1-based Fenwick tree
	first, end int
	mountedRows int
	renderedBlocks int
}

const virtualOverscanRows = 8

func newVirtualTranscript(width, height int) *virtualTranscript {
	return &virtualTranscript{width:max(1,width),height:max(1,height),followEnd:true,bit:[]int{0}}
}
func (v *virtualTranscript) reset() {
	v.heights=nil
	v.bit=[]int{0}
	v.top=0
	v.followEnd=true
	v.first=0
	v.end=0
	v.mountedRows=0
}

func (v *virtualTranscript) prefix(i int) int {
	i=min(max(i,0),len(v.heights))
	sum:=0
	for i>0 {sum+=v.bit[i];i-=i&-i}
	return sum
}
func (v *virtualTranscript) totalRows() int {return v.prefix(len(v.heights))}
func (v *virtualTranscript) heightAt(i int) int {
	if i<0||i>=len(v.heights) {return 1}
	return v.heights[i]
}
func (v *virtualTranscript) setHeight(i, height int) {
	if i<0||i>=len(v.heights) {return}
	height=max(1,height)
	delta:=height-v.heights[i]
	if delta==0 {return}
	v.heights[i]=height
	for j:=i+1;j<len(v.bit);j+=j&-j {v.bit[j]+=delta}
}
func (v *virtualTranscript) appendHeight(height int) {
	height=max(1,height)
	i:=len(v.heights)+1
	lowbit:=i&-i
	// The new Fenwick entry covers [i-lowbit+1, i]; previous entries
	// already contain all but the just-appended height.
	prior:=v.prefix(i-1)-v.prefix(i-lowbit)
	v.heights=append(v.heights,height)
	v.bit=append(v.bit,prior+height)
}

// indexAt resolves the block containing the given logical row in O(log N).
func (v *virtualTranscript) indexAt(row int) int {
	n:=len(v.heights)
	if n==0 {return 0}
	row=min(max(0,row),max(0,v.totalRows()-1))
	index:=0
	for step:=1<<uint(bitsForIndex(n));step>0;step>>=1 {
		next:=index+step
		if next<=n&&v.bit[next]<=row {
			row-=v.bit[next]
			index=next
		}
	}
	return min(index,n-1)
}
func bitsForIndex(n int) int {
	bits:=0
	for 1<<uint(bits)<=n {bits++}
	return bits
}

// Estimates require only raw text, not a Markdown render. They are corrected
// as each block is mounted and measured in the terminal's actual width.
func estimateTranscriptHeight(raw string, width int) int {
	width=max(1,width)
	rows:=2 // between-message spacer, also retained for the final block
	for _,line:=range strings.Split(raw,"\n") {
		rows+=max(1,int(math.Ceil(float64(lipgloss.Width(line))/float64(width))))
	}
	return max(3,rows)
}

// sync extends incrementally on append. Width changes and wholesale session
// replacements rebuild the index once, not every token or keypress.
func (v *virtualTranscript) sync(count, width, height int, rawAt func(int)string) {
	width=max(1,width)
	height=max(1,height)
	widthChanged:=v.width!=width
	anchor,offset:=0,0
	if widthChanged&&len(v.heights)>0&&!v.followEnd {
		anchor=v.indexAt(v.top)
		offset=v.top-v.prefix(anchor)
	}
	if widthChanged||count<len(v.heights) {
		v.heights=nil
		v.bit=[]int{0}
	}
	v.width=width
	v.height=height
	for i:=len(v.heights);i<count;i++ {
		v.appendHeight(estimateTranscriptHeight(rawAt(i),width))
	}
	if widthChanged&&!v.followEnd&&len(v.heights)>0 {
		anchor=min(anchor,len(v.heights)-1)
		v.top=v.prefix(anchor)+min(offset,v.heightAt(anchor)-1)
	}
	v.clamp()
}
func (v *virtualTranscript) clamp() {
	bottom:=max(0,v.totalRows()-v.height)
	if v.followEnd {v.top=bottom} else {v.top=min(max(0,v.top),bottom)}
}
func (v *virtualTranscript) scroll(delta int) {
	if delta==0 {return}
	v.top=min(max(0,v.top+delta),max(0,v.totalRows()-v.height))
	v.followEnd=v.top>=max(0,v.totalRows()-v.height)
}
func (v *virtualTranscript) jumpToBlock(index int) {
	if index<0||index>=len(v.heights) {return}
	v.top=min(v.prefix(index),max(0,v.totalRows()-v.height))
	v.followEnd=false
}

// rawTranscriptBlock uses the original source, including the transient
// streaming and reasoning blocks which have not yet settled into history.
func (m *model) rawTranscriptBlock(index int) string {
	if index<len(m.transcript) {return m.transcript[index]}
	index-=len(m.transcript)
	if m.showThinking&&m.reasoning!="" {
		if index==0 {return "Thinking: "+m.reasoning}
		index--
	}
	if index==0&&m.streaming!="" {return m.streaming}
	return ""
}
func (m *model) transcriptBlockCount() int {
	count:=len(m.transcript)
	if m.showThinking&&m.reasoning!="" {count++}
	if m.streaming!="" {count++}
	return count
}

func (m *model) mountedTranscriptBlock(index int) string {
	raw:=m.rawTranscriptBlock(index)
	if _,markdown:=m.markdownRaw[index];!markdown||m.markdownRenderer==nil {
		return raw
	}
	if rendered,ok:=m.markdownCache[index];ok {return rendered}
	rendered:=raw
	if result,err:=m.markdownRenderer.Render(raw);err==nil {
		rendered=strings.TrimRight(result,"\n")
	}
	if m.markdownCache==nil {m.markdownCache=make(map[int]string)}
	m.markdownCache[index]=rendered
	return rendered
}
func (m *model) resetVirtualTranscript() {
	if m.virtualScroll!=nil {m.virtualScroll.reset()}
	m.markdownCache=nil
}
func (m *model) invalidateTranscriptBlock(index int) {
	if m.markdownCache!=nil {delete(m.markdownCache,index)}
	if v:=m.virtualScroll;v!=nil&&index>=0&&index<len(v.heights) {
		v.setHeight(index,estimateTranscriptHeight(m.rawTranscriptBlock(index),v.width))
	}
}
func (m *model) scrollTranscript(delta int) {
	if m.virtualScroll==nil {return}
	m.virtualScroll.scroll(delta)
	m.refreshTranscript()
}
func (m *model) jumpToTranscriptBlock(index int) {
	if m.virtualScroll==nil {return}
	m.virtualScroll.jumpToBlock(index)
	m.refreshTranscript()
}

// refreshTranscript now makes a bounded mounted window. All movement and
// redraw paths use this method, but never join the complete conversation.
func (m *model) refreshTranscript() {
	if m.virtualScroll==nil {
		m.virtualScroll=newVirtualTranscript(m.viewport.Width(),m.viewport.Height())
	}
	v:=m.virtualScroll
	count:=m.transcriptBlockCount()
	v.sync(count,m.viewport.Width(),m.viewport.Height(),m.rawTranscriptBlock)
	if count==0 {
		m.viewport.SetContent("")
		m.viewport.SetYOffset(0)
		return
	}
	anchor:=v.indexAt(v.top)
	intra:=v.top-v.prefix(anchor)
	endRow:=v.top+v.height+virtualOverscanRows
	start:=anchor
	lines:=make([]string,0,v.height+virtualOverscanRows+12)
	mounted:=make(map[int]bool)
	v.renderedBlocks=0
	for i:=start;i<count&&v.prefix(i)<endRow;i++ {
		text:=m.mountedTranscriptBlock(i)
		// SoftWrap on the local viewport and row estimates use the same cell
		// widths. This keeps the source line intact (including ANSI styling).
		blockLines:=strings.Split(text,"\n")
		blockLines=append(blockLines,"","")
		rows:=0
		for _,line:=range blockLines {
			rows+=max(1,(lipgloss.Width(line)+v.width-1)/v.width)
		}
		v.setHeight(i,rows)
		lines=append(lines,blockLines...)
		mounted[i]=true
		v.renderedBlocks++
	}
	if !v.followEnd {
		v.top=v.prefix(anchor)+min(intra,v.heightAt(anchor)-1)
	}
	v.clamp()
	v.first=start
	v.end=start+v.renderedBlocks
	v.mountedRows=len(lines)
	// Keep Markdown cache proportional to the mounted window, not session
	// length. On resize, cached wrapping is discarded by resize().
	for i:=range m.markdownCache {
		if !mounted[i] {delete(m.markdownCache,i)}
	}
	m.viewport.SetContentLines(lines)
	m.viewport.SetYOffset(v.top-v.prefix(start))
}
