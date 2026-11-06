// Package main hosts the Cetas terminal in Bubble Tea v2. MoonBit/Posoco
// remains the sole authority for provider, session and turn state.
package main

import (
 "context"
 "encoding/json"
 "fmt"
 "os"
 "strings"
 "time"

 "charm.land/bubbles/v2/textarea"
 "charm.land/bubbles/v2/viewport"
 tea "charm.land/bubbletea/v2"
 "charm.land/lipgloss/v2"

 "github.com/colmugx/cetas/cetas-native/harness"
)

type runtimeHost interface {
 Request(context.Context, string, any) (json.RawMessage, error)
 Events() <-chan harness.Event
 Close(context.Context) error
}

type commandResult struct {
 name string
 payload json.RawMessage
 err error
}
type eventResult struct {
 event harness.Event
 ok bool
}
type bootResult struct {
 host *harness.Host
 err error
}

type model struct {
 host runtimeHost
 feed <-chan harness.Event
 textarea textarea.Model
 viewport viewport.Model
 width, height int
 transcript []string
 streaming strings.Builder
 reasoning strings.Builder
 running bool
 modal string
 modalItems []string
 modalIndex int
 modelSlots []struct {
  ID string `json:"id"`
  Label string `json:"label"`
  Model string `json:"model"`
  Active bool `json:"active"`
 }
 session string
 status string
 err string
 showThinking bool
 showTools bool
}

func newModel() model {
 ta:=textarea.New()
 ta.Placeholder="Ask Cetas or type /help"
 ta.Prompt="> "
 ta.SetWidth(78)
 ta.SetHeight(3)
 ta.Focus()
 ta.KeyMap.InsertNewline.SetEnabled(false)
 vp:=viewport.New(viewport.WithWidth(80),viewport.WithHeight(18))
 vp.SetWidth(80)
 vp.SetHeight(18)
 return model{textarea:ta,viewport:vp,status:"connecting to Posoco…"}
}

func boot() tea.Msg {
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second)
 defer cancel()
 h,e:=harness.Start(ctx)
 return bootResult{host:h,err:e}
}
func receive(events <-chan harness.Event) tea.Cmd {
 return func() tea.Msg { e,ok:=<-events; return eventResult{event:e,ok:ok} }
}
func request(host runtimeHost, command string, args any) tea.Cmd {
 return func() tea.Msg {
  ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second)
  defer cancel()
  result,err:=host.Request(ctx,command,args)
  return commandResult{name:command,payload:result,err:err}
 }
}
func (m model) Init() tea.Cmd { return boot }
func (m model) Update(message tea.Msg) (tea.Model,tea.Cmd) {
 switch msg:=message.(type) {
 case tea.WindowSizeMsg:
  m.width,m.height=msg.Width,msg.Height
  m.resize()
  return m,nil
 case bootResult:
  if msg.err!=nil {m.status="startup failed";m.err=msg.err.Error();return m,nil}
  m.host=msg.host;m.feed=msg.host.Events();m.status="ready"
  return m,tea.Batch(receive(m.feed),request(m.host,"runtime_state",map[string]string{}))
 case eventResult:
  if !msg.ok {m.status="MoonBit host stopped";return m,nil}
  m.applyEvent(msg.event)
  return m,receive(m.feed)
 case commandResult:
  if msg.err!=nil {m.err=msg.name+": "+msg.err.Error();return m,nil}
  if msg.name=="models" {
   var x struct{ Models []struct {
    ID string `json:"id"`
    Label string `json:"label"`
    Model string `json:"model"`
    Active bool `json:"active"`
   } `json:"models"`; Slots []struct {
    ID string `json:"id"`
    Label string `json:"label"`
    Model string `json:"model"`
    Active bool `json:"active"`
   } `json:"slots"` }
   if json.Unmarshal(msg.payload,&x)==nil {
    m.modelSlots=x.Models
    if len(m.modelSlots)==0 {m.modelSlots=x.Slots}
    m.modal="models";m.modalItems=nil;m.modalIndex=0
    for _,s:=range m.modelSlots {m.modalItems=append(m.modalItems,s.Label)}
   }
  }
  if msg.name=="runtime_state" {
   var s struct{SessionID string `json:"session_id"`;Status string `json:"status"`}
   if json.Unmarshal(msg.payload,&s)==nil {m.session=s.SessionID}
  }
  return m,nil
 case tea.KeyPressMsg:
  key:=msg.String()
  if key=="ctrl+c" {return m,tea.Quit}
  if m.modal!="" {
   switch key {
   case "esc":m.modal="";m.modalItems=nil
   case "up","ctrl+p":if m.modalIndex>0 {m.modalIndex--}
   case "down","ctrl+n":if m.modalIndex+1<len(m.modalItems) {m.modalIndex++}
   case "enter":
    if m.modal=="models"&&m.modalIndex<len(m.modelSlots)&&m.host!=nil {
     id:=m.modelSlots[m.modalIndex].ID;m.modal="";return m,request(m.host,"switch_model",map[string]any{"slot_id":id})
    }
    m.modal=""
   }
   return m,nil
  }
  switch key {
  case "ctrl+o":m.showTools=!m.showTools;return m,nil
  case "ctrl+t":m.showThinking=!m.showThinking;return m,nil
  case "esc":
   if m.host!=nil&&m.running {return m,request(m.host,"turn_abort",map[string]any{})}
   return m,nil
  case "enter":
   value:=strings.TrimSpace(m.textarea.Value())
   if value=="" {return m,nil}
   if m.host==nil {m.err="Posoco is not connected";return m,nil}
   m.textarea.Reset()
   if strings.HasPrefix(value,"/") {return m,m.command(value)}
   m.transcript=append(m.transcript,"> "+value)
   m.refreshTranscript()
   return m,request(m.host,"turn_start",map[string]any{"prompt":value})
  case "shift+enter","ctrl+j":m.textarea.InsertString("\n");return m,nil
  }
 }
 var cmd tea.Cmd
 m.textarea,cmd=m.textarea.Update(message)
 return m,cmd
}

func (m model) command(value string) tea.Cmd {
 parts:=strings.Fields(value)
 switch parts[0] {
 case "/model":return request(m.host,"models",map[string]any{})
 case "/new":return request(m.host,"switch_session",map[string]any{})
 case "/compact":return request(m.host,"session_compact",map[string]any{})
 case "/permission":
  if len(parts)>1 {return request(m.host,"set_permission",map[string]any{"mode":parts[1]})}
 case "/help":return func() tea.Msg {return commandResult{name:"help",payload:json.RawMessage(`{"ok":true}`)}}
 }
 return func() tea.Msg {return commandResult{name:value,err:fmt.Errorf("command not available in this migration checkpoint")}}
}

func (m *model) applyEvent(e harness.Event) {
 var frame struct {
  Type string `json:"type"`
  Text string `json:"text"`
  Delta string `json:"delta"`
  Token string `json:"token"`
  Message string `json:"message"`
  ToolName string `json:"tool_name"`
  SessionID string `json:"session_id"`
 }
 if json.Unmarshal(e.Raw,&frame)!=nil {return}
 if frame.SessionID!="" {m.session=frame.SessionID}
 switch frame.Type {
 case "turn.accepted","turn.started":m.running=true;m.status="working"
 case "assistant.text_delta":
  delta:=frame.Delta
  if delta=="" {delta=frame.Text};if delta=="" {delta=frame.Token}
  m.streaming.WriteString(delta)
 case "assistant.reasoning_delta":
  delta:=frame.Delta
  if delta=="" {delta=frame.Text};if delta=="" {delta=frame.Token}
  m.reasoning.WriteString(delta)
 case "tool.started":
  m.transcript=append(m.transcript,"• "+frame.ToolName+" …")
 case "tool.completed":
  if m.showTools {m.transcript=append(m.transcript,"  "+frame.ToolName+" completed")}
 case "turn.completed":
  text:=m.streaming.String();if text=="" {text=frame.Text}
  if text!="" {m.transcript=append(m.transcript,text)}
  if m.showThinking&&m.reasoning.Len()>0 {m.transcript=append(m.transcript,"Thinking: "+m.reasoning.String())}
  m.streaming.Reset();m.reasoning.Reset();m.running=false;m.status="ready"
 case "turn.failed":
  m.transcript=append(m.transcript,"Error: "+frame.Message)
  m.streaming.Reset();m.reasoning.Reset();m.running=false;m.status="failed"
 case "session.redirect":m.status="session redirected"
 case "ui.request":m.status="interactive approval requested (native UI migration pending)"
 }
 m.refreshTranscript()
}

func (m *model) refreshTranscript() {
 items:=append([]string(nil),m.transcript...)
 if m.showThinking&&m.reasoning.Len()>0 {items=append(items,"Thinking: "+m.reasoning.String())}
 if m.streaming.Len()>0 {items=append(items,m.streaming.String())}
 m.viewport.SetContent(strings.Join(items,"\n\n"))
 m.viewport.GotoBottom()
}
func (m *model) resize() {
 width:=max(20,m.width-2)
 m.textarea.SetWidth(width)
 m.viewport.SetWidth(width)
 m.viewport.SetHeight(max(1,m.height-10))
 m.refreshTranscript()
}
func (m model) View() tea.View {
 var content strings.Builder
 header:=lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#69C8C0")).Render("Cetas Native  /  Bubble Tea + Posoco")
 content.WriteString(header+"\n")
 content.WriteString(lipgloss.NewStyle().Faint(true).Render("session: "+m.session)+"\n\n")
 if m.modal!="" {
  content.WriteString("Select model (↑/↓, Enter, Esc):\n")
  for i,s:=range m.modalItems {if i==m.modalIndex {content.WriteString("▶ ")} else {content.WriteString("  ")};content.WriteString(s+"\n")}
 } else {
  content.WriteString(m.viewport.View()+"\n")
  content.WriteString(m.textarea.View()+"\n")
 }
 content.WriteString(" "+m.status+"  |  Enter send  Shift+Enter newline  Esc interrupt  Ctrl+C quit")
 if m.err!="" {content.WriteString("\n"+lipgloss.NewStyle().Foreground(lipgloss.Color("#D64C4C")).Render(m.err))}
 view:=tea.NewView(content.String())
 view.AltScreen=true
 if m.modal=="" {if cursor:=m.textarea.Cursor();cursor!=nil {cursor.Y+=m.viewport.Height()+2;view.Cursor=cursor}}
 return view
}
func main() {
 p:=tea.NewProgram(newModel())
 if _,err:=p.Run();err!=nil {fmt.Fprintln(os.Stderr,err);os.Exit(1)}
}
