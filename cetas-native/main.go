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
 modalValues []string
 modalIndex int
 modalRequestID string
 modalPrompt string
 modalBuffer []rune
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
    m.modalValues=nil
    for _,s:=range m.modelSlots {m.modalItems=append(m.modalItems,s.Label);m.modalValues=append(m.modalValues,s.ID)}
   }
  }
  if msg.name=="sessions" {
   var payload struct{Sessions []struct{ID string `json:"id"`;Title string `json:"title"`;Active bool `json:"active"`} `json:"sessions"`}
   if json.Unmarshal(msg.payload,&payload)==nil {
    m.modal="sessions";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
    for _,v:=range payload.Sessions {title:=v.Title;if title=="" {title=v.ID};if v.Active {title="● "+title};m.modalItems=append(m.modalItems,title);m.modalValues=append(m.modalValues,v.ID)}
   }
  }
  if msg.name=="providers" {
   var payload struct{Providers []struct{ID string `json:"id"`;Name string `json:"name"`;SignedIn bool `json:"signed_in"`} `json:"providers"`}
   if json.Unmarshal(msg.payload,&payload)==nil {
    m.modal="providers";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
    for _,v:=range payload.Providers {title:=v.Name;if title=="" {title=v.ID};if v.SignedIn {title+=" (signed in)"};m.modalItems=append(m.modalItems,title);m.modalValues=append(m.modalValues,v.ID)}
   }
  }
  if msg.name=="help" {m.transcript=append(m.transcript,"/model · /sessions · /new · /login [provider] · /logout provider · /permission mode · /compact · /help");m.refreshTranscript()}
  if msg.name=="runtime_state" {
   var s struct{SessionID string `json:"session_id"`;Status string `json:"status"`}
   if json.Unmarshal(msg.payload,&s)==nil {m.session=s.SessionID}
  }
  return m,nil
 case tea.KeyPressMsg:
  key:=msg.String()
  if key=="ctrl+c" {return m,tea.Quit}
  if m.modal!="" {
   if m.modalRequestID!="" {
    switch key {
    case "esc":return m,m.answerModal(map[string]any{"cancelled":true})
    case "enter":
     switch m.modal {
     case "input":return m,m.answerModal(map[string]any{"text":string(m.modalBuffer)})
     case "select":return m,m.answerModal(map[string]any{"selected":m.modalIndex})
     case "confirm":if m.modalIndex==0{return m,m.answerModal(map[string]any{"yes":true})};return m,m.answerModal(map[string]any{"no":false})
     }
    case "up","ctrl+p":if m.modalIndex>0 {m.modalIndex--};return m,nil
    case "down","ctrl+n":if m.modalIndex+1<len(m.modalItems) {m.modalIndex++};return m,nil
    case "backspace":if m.modal=="input"&&len(m.modalBuffer)>0 {m.modalBuffer=m.modalBuffer[:len(m.modalBuffer)-1]};return m,nil
    default:if m.modal=="input"&&msg.Text!="" {m.modalBuffer=append(m.modalBuffer,[]rune(msg.Text)...)};return m,nil
    }
   }
   switch key {
   case "esc":m.modal="";m.modalItems=nil;m.modalValues=nil
   case "up","ctrl+p":if m.modalIndex>0 {m.modalIndex--}
   case "down","ctrl+n":if m.modalIndex+1<len(m.modalItems) {m.modalIndex++}
   case "enter":
    if m.host!=nil&&m.modalIndex<len(m.modalValues) {
     chosen:=m.modalValues[m.modalIndex]
     switch m.modal {
     case "models":m.modal="";m.modalValues=nil;return m,request(m.host,"switch_model",map[string]any{"slot_id":chosen})
     case "sessions":m.modal="";m.modalValues=nil;return m,request(m.host,"switch_session",map[string]any{"id":chosen})
     case "providers":m.modal="";m.modalValues=nil;return m,request(m.host,"login",map[string]any{"provider":chosen})
     }
    }
    m.modal="";m.modalValues=nil
   }
   return m,nil
  }
  switch key {
  case "ctrl+o":m.showTools=!m.showTools;return m,nil
  case "ctrl+t":m.showThinking=!m.showThinking;return m,nil
  case "esc":
   if m.host!=nil&&m.running {return m,request(m.host,"turn_abort",map[string]any{})}
   return m,nil
  case "pgup","pageup":m.viewport.ScrollUp(max(1,m.viewport.Height()/2));return m,nil
  case "pgdown","pagedown":m.viewport.ScrollDown(max(1,m.viewport.Height()/2));return m,nil
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

func (m *model) answerModal(answer map[string]any) tea.Cmd {
 id:=m.modalRequestID
 answer["request_id"]=id
 m.modal="";m.modalRequestID="";m.modalItems=nil;m.modalBuffer=nil;m.modalPrompt=""
 return request(m.host,"ui_response",answer)
}

func (m model) command(value string) tea.Cmd {
 parts:=strings.Fields(value)
 switch parts[0] {
 case "/model":return request(m.host,"models",map[string]any{})
 case "/new":return request(m.host,"switch_session",map[string]any{})
 case "/login":if len(parts)>1 {method:="";if len(parts)>2 {method=parts[2]};return request(m.host,"login",map[string]any{"provider":parts[1],"method":method})};return request(m.host,"providers",map[string]any{})
 case "/logout":if len(parts)>1 {return request(m.host,"logout",map[string]any{"provider":parts[1]})}
 case "/sessions":return request(m.host,"sessions",map[string]any{})
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
  RequestID string `json:"request_id"`
  Kind string `json:"kind"`
  Prompt string `json:"prompt"`
  Options []string `json:"options"`
  Slot string `json:"slot"`
  Lines []string `json:"lines"`
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
 case "ui.request":
  m.modalRequestID=frame.RequestID;m.modal=frame.Kind;m.modalPrompt=frame.Prompt
  m.modalBuffer=nil;m.modalIndex=0;m.modalItems=append([]string(nil),frame.Options...)
  if frame.Kind=="confirm" {m.modalItems=[]string{"Yes","No"}}
  m.status="waiting for user input"
 case "ui.render":
  if frame.Slot=="Notice"||frame.Slot=="Widget" {text:=frame.Text;if len(frame.Lines)>0 {text=strings.Join(frame.Lines,"\n")};if text!="" {m.transcript=append(m.transcript,text)}}
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
 result,err:=p.Run()
 if state,ok:=result.(model);ok && state.host!=nil {
  ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second)
  if closeErr:=state.host.Close(ctx);closeErr!=nil {fmt.Fprintln(os.Stderr,"shutdown:",closeErr)}
  cancel()
 }
 if err!=nil {fmt.Fprintln(os.Stderr,err);os.Exit(1)}
}
