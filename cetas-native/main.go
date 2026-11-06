// Package main hosts the Cetas terminal in Bubble Tea v2. MoonBit/Posoco
// remains the sole authority for provider, session and turn state.
package main

import (
 "context"
 "encoding/json"
 "fmt"
 "os"
 "strconv"
 "strings"
 "time"

 "charm.land/bubbles/v2/textarea"
 "charm.land/bubbles/v2/viewport"
 tea "charm.land/bubbletea/v2"
 "charm.land/lipgloss/v2"
 "charm.land/glamour/v2"

 "github.com/colmugx/cetas/cetas-native/harness"
)

type runtimeHost interface {
 Request(context.Context, string, any) (json.RawMessage, error)
 Events() <-chan harness.Event
 Errors() <-chan error
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
type eventBatchResult struct {
 events []harness.Event
 closed bool
}
type errorResult struct {
 err error
 ok bool
}
type uiPrompt struct { id, kind, prompt string; options []string; defaultValue json.RawMessage }

type bootResult struct {
 host *harness.Host
 err error
}

type model struct {
 host runtimeHost
 feed <-chan harness.Event
 textarea textarea.Model
 viewport viewport.Model
 virtualScroll *virtualTranscript
 width, height int
 transcript []string
 searchQuery string
 searchHits []transcriptSearchHit
 searchActive int
 hiddenSearchSources []hiddenTranscriptSource
 markdownRaw map[int]string
 toolIndex map[string]int
 markdownCache map[int]string
 markdownRenderer *glamour.TermRenderer
 streaming string
 reasoning string
 running bool
 modal string
 modalItems []string
 modalValues []string
 modalIndex int
 modalRequestID string
 modalPrompt string
 modalBuffer []rune
 pendingUI []uiPrompt
 followups []string
 completionPrefix string
 completionToken string
 modelSlots []struct {
  ID string `json:"id"`
  Label string `json:"label"`
  Model string `json:"model"`
  Active bool `json:"active"`
  Efforts []string `json:"efforts"`
 }
 nextPicker string
 lastEscape time.Time
 pendingProvider string
 authID string
 providerMethods map[string][]string
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
 renderer,_:=glamour.NewTermRenderer(glamour.WithWordWrap(78))
 vp:=viewport.New(viewport.WithWidth(80),viewport.WithHeight(18))
 vp.SetWidth(80)
 vp.SetHeight(18)
 vp.SoftWrap=true
 return model{textarea:ta,viewport:vp,markdownRenderer:renderer,status:"connecting to Posoco…",searchActive:-1}
}

func boot() tea.Msg {
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second)
 defer cancel()
 h,e:=harness.Start(ctx)
 return bootResult{host:h,err:e}
}
func receive(events <-chan harness.Event) tea.Cmd {
 return func() tea.Msg {
  first,ok:=<-events
  if !ok {return eventBatchResult{closed:true}}
  result:=eventBatchResult{events:[]harness.Event{first}}
  // One native command drains a bounded burst, respecting EventHub order.
  // A single Bubble Tea render then covers many rapid token deltas.
  for len(result.events)<64 {
   select {
   case e,ok:=<-events:
    if !ok {result.closed=true;return result}
    result.events=append(result.events,e)
   default:return result
   }
  }
  return result
 }
}
func receiveErrors(errors <-chan error) tea.Cmd {
 return func() tea.Msg {err,ok:=<-errors;return errorResult{err:err,ok:ok}}
}
func request(host runtimeHost, command string, args any) tea.Cmd {
 return requestAs(host,command,command,args)
}
// requestAs preserves the wire command while distinguishing independent UI
// intents that otherwise race on the same asynchronous reply.
func requestAs(host runtimeHost, name, command string, args any) tea.Cmd {
 return func() tea.Msg {
  ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second)
  defer cancel()
  result,err:=host.Request(ctx,command,args)
  return commandResult{name:name,payload:result,err:err}
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
  return m,tea.Batch(receive(m.feed),receiveErrors(m.host.Errors()),request(m.host,"runtime_state",map[string]string{}))
 case errorResult:
  if !msg.ok {return m,nil}
  if msg.err!=nil {m.err=msg.err.Error();m.status="runtime problem"}
  return m,receiveErrors(m.host.Errors())
 case eventBatchResult:
  var next string
  for _,e:=range msg.events {
   var meta struct{Type string `json:"type"`;Busy bool `json:"busy"`;SessionID string `json:"session_id"`}
   _=json.Unmarshal(e.Raw,&meta)
   m.applyEvent(e)
   if meta.Type=="session.snapshot"&&!meta.Busy&&meta.SessionID==m.session&&len(m.followups)>0&&next=="" {
    next=m.followups[0];m.followups=m.followups[1:];m.running=true
   }
  }
  m.refreshTranscript()
  if msg.closed {m.status="MoonBit host stopped";return m,nil}
  if next!="" {return m,tea.Batch(receive(m.feed),request(m.host,"turn_start",map[string]any{"prompt":next,"session_id":m.session}))}
  return m,receive(m.feed)
 case eventResult:
  if !msg.ok {m.status="MoonBit host stopped";return m,nil}
  var meta struct {Type string `json:"type"`;Busy bool `json:"busy"`;SessionID string `json:"session_id"`}
  _=json.Unmarshal(msg.event.Raw,&meta)
  m.applyEvent(msg.event)
  m.refreshTranscript()
  if meta.Type=="session.snapshot"&&!meta.Busy&&meta.SessionID==m.session&&len(m.followups)>0 {
   next:=m.followups[0];m.followups=m.followups[1:];m.running=true
   return m,tea.Batch(receive(m.feed),request(m.host,"turn_start",map[string]any{"prompt":next,"session_id":m.session}))
  }
  return m,receive(m.feed)
 case commandResult:
  if msg.err!=nil {m.err=msg.name+": "+msg.err.Error();if msg.name=="turn_start" {m.running=false};return m,nil}
  // Harness can return a protocol-level error inside an otherwise valid
  // correlated response. It is not a transport failure; still render it and
  // do not accidentally treat it as successful rewind/login/turn dispatch.
  var failure struct{Error string `json:"error"`}
  if json.Unmarshal(msg.payload,&failure)==nil && failure.Error!="" {
   m.err=msg.name+": "+failure.Error
   if msg.name=="turn_start" {m.running=false}
   return m,nil
  }
  if msg.name=="login" {
   var started struct{Status string `json:"status"`; AuthID string `json:"auth_id"`; Provider string `json:"provider"`}
   if json.Unmarshal(msg.payload,&started)==nil && started.Status=="started" && started.AuthID!="" {
    m.authID=started.AuthID
    m.status="authenticating "+started.Provider+" (Esc cancels)"
   }
  }
  if msg.name=="login_cancel" {
   var outcome struct{Cancelled bool `json:"cancelled"`;AuthID string `json:"auth_id"`}
   if json.Unmarshal(msg.payload,&outcome)==nil && outcome.AuthID==m.authID&&!outcome.Cancelled {
    m.status="authentication already settled"
    m.authID=""
   }
  }
  if msg.name=="models" {
   var x struct{ Models []struct {
    ID string `json:"id"`
    Label string `json:"label"`
    Model string `json:"model"`
    Active bool `json:"active"`
    Efforts []string `json:"efforts"`
   } `json:"models"`; Slots []struct {
    ID string `json:"id"`
    Label string `json:"label"`
    Model string `json:"model"`
    Active bool `json:"active"`
    Efforts []string `json:"efforts"`
   } `json:"slots"` }
   if json.Unmarshal(msg.payload,&x)==nil {
    m.modelSlots=x.Models
    if len(m.modelSlots)==0 {m.modelSlots=x.Slots}
    m.modal="models";m.modalItems=nil;m.modalIndex=0;m.modalValues=nil
    if m.nextPicker=="efforts" {
     m.modal="efforts"
     for _,slot:=range m.modelSlots {if slot.Active {for _,effort:=range slot.Efforts {m.modalItems=append(m.modalItems,effort);m.modalValues=append(m.modalValues,effort)}}}
    } else {for _,slot:=range m.modelSlots {m.modalItems=append(m.modalItems,slot.Label);m.modalValues=append(m.modalValues,slot.ID)}}
    m.nextPicker=""
   }
  }
  if msg.name=="file_search" {
   var data struct{Query string `json:"query"`;Entries []struct{Path string `json:"path"`} `json:"entries"`}
   if json.Unmarshal(msg.payload,&data)==nil && m.completionToken=="@"+data.Query && strings.HasSuffix(m.textarea.Value(),m.completionToken) {
    m.modal="files";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
    for _,v:=range data.Entries {m.modalItems=append(m.modalItems,v.Path);m.modalValues=append(m.modalValues,v.Path)}
   }
  }
  if msg.name=="skills"||msg.name=="skills_browse" {
   var data struct{Skills []struct{Name string `json:"name"`;Description string `json:"description"`} `json:"skills"`}
   if json.Unmarshal(msg.payload,&data)==nil {
    // A delayed skills catalog must not steal focus from an approval or an
    // unrelated picker opened after the request was sent.
    if m.modal!="" {return m,nil}
    if msg.name=="skills" && (m.completionToken=="" || !strings.HasSuffix(m.textarea.Value(),m.completionToken)) {return m,nil}
    m.modal="skills";if msg.name=="skills_browse" {m.modal="skills_browse"}
    m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
    for _,v:=range data.Skills {
     if msg.name=="skills" && !strings.Contains(strings.ToLower(v.Name),strings.ToLower(strings.TrimPrefix(m.completionToken,"$"))) {continue}
     m.modalItems=append(m.modalItems,v.Name+" "+v.Description);m.modalValues=append(m.modalValues,v.Name)
    }
   }
  }
  if msg.name=="rewind_points" {
   var data struct{Points []struct{MessageIndex int `json:"message_index"`;Preview string `json:"preview"`} `json:"points"`}
   if json.Unmarshal(msg.payload,&data)==nil {
    m.modal="rewind";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
    for _,point:=range data.Points {m.modalItems=append(m.modalItems,point.Preview);m.modalValues=append(m.modalValues,strconv.Itoa(point.MessageIndex))}
    if len(m.modalItems)==0 {m.modal="";m.status="no rewind points"}
   }
  }
  if msg.name=="rewind_apply" {
   var data struct{Text string `json:"text"`;SessionID string `json:"session_id"`}
   if json.Unmarshal(msg.payload,&data)==nil {
    m.textarea.SetValue(data.Text);m.textarea.Focus()
    m.streaming="";m.reasoning="";m.running=false;m.followups=nil
    return m,request(m.host,"session_transcript",map[string]any{"id":m.session})
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
   var payload struct{Providers []struct{ID string `json:"id"`;Name string `json:"name"`;SignedIn bool `json:"signed_in"`;Methods []string `json:"methods"`} `json:"providers"`}
   if json.Unmarshal(msg.payload,&payload)==nil {
    m.modal="providers";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil;m.providerMethods=map[string][]string{}
    for _,v:=range payload.Providers {
     m.providerMethods[v.ID]=append([]string(nil),v.Methods...);title:=v.Name;if title=="" {title=v.ID};if v.SignedIn {title+=" (signed in)"};m.modalItems=append(m.modalItems,title);m.modalValues=append(m.modalValues,v.ID)}
   }
  }
  if msg.name=="switch_session" {
   var payload struct{SessionID string `json:"session_id"`}
   if json.Unmarshal(msg.payload,&payload)==nil && payload.SessionID!="" {
    m.session=payload.SessionID;m.clearTranscriptSearch();m.resetVirtualTranscript();m.transcript=nil;m.markdownRaw=nil;m.markdownCache=nil;m.toolIndex=nil;m.streaming="";m.reasoning="";m.running=false;m.followups=nil
    return m,request(m.host,"session_transcript",map[string]any{"id":m.session})
   }
  }
  if msg.name=="session_transcript" {
   var payload struct{ Items []struct{Kind string `json:"kind"`;Text string `json:"text"`;Name string `json:"name"`;Result string `json:"result"`} `json:"items"` }
   if json.Unmarshal(msg.payload,&payload)==nil {
    m.clearTranscriptSearch();m.resetVirtualTranscript();m.transcript=nil;m.markdownRaw=nil;m.markdownCache=nil;m.toolIndex=nil
    for _,row:=range payload.Items {
     switch row.Kind {
     case "user":m.transcript=append(m.transcript,"> "+row.Text)
     case "assistant":m.appendAssistant(row.Text)
     case "reasoning":
       if m.showThinking {m.transcript=append(m.transcript,"Thinking: "+row.Text)} else {m.addHiddenSource(max(0,len(m.transcript)-1),"Thinking: "+row.Text)}
     case "tool":
       m.transcript=append(m.transcript,"• "+row.Name)
       if row.Result!="" {
        if m.showTools {m.transcript=append(m.transcript,row.Result)} else {m.addHiddenSource(len(m.transcript)-1,row.Result)}
       }
     }
    }
    m.refreshTranscript()
   }
  }
  if msg.name=="help" {m.transcript=append(m.transcript,nativeSlashHelp());m.refreshTranscript()}
  if msg.name=="runtime_state" {
   var snapshot struct{SessionID string `json:"session_id"`;Status string `json:"status"`}
   if json.Unmarshal(msg.payload,&snapshot)==nil && snapshot.SessionID!="" {
    firstAttach:=m.session==""
    m.session=snapshot.SessionID
    if firstAttach {return m,request(m.host,"session_transcript",map[string]any{"id":m.session})}
   }
  }
  return m,nil
 case tea.MouseWheelMsg:
  if m.modal=="" {
   switch msg.Button {
   case tea.MouseWheelUp:m.scrollTranscript(-3)
   case tea.MouseWheelDown:m.scrollTranscript(3)
   }
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
     case "input","secret":return m,m.answerModal(map[string]any{"text":string(m.modalBuffer)})
     case "select":return m,m.answerModal(map[string]any{"selected":m.modalIndex})
     case "confirm":if m.modalIndex==0{return m,m.answerModal(map[string]any{"yes":true})};return m,m.answerModal(map[string]any{"no":false})
     }
    case "up","ctrl+p":if m.modalIndex>0 {m.modalIndex--};return m,nil
    case "down","ctrl+n":if m.modalIndex+1<len(m.modalItems) {m.modalIndex++};return m,nil
    case "backspace":if (m.modal=="input"||m.modal=="secret")&&len(m.modalBuffer)>0 {m.modalBuffer=m.modalBuffer[:len(m.modalBuffer)-1]};return m,nil
    default:if (m.modal=="input"||m.modal=="secret")&&msg.Text!="" {m.modalBuffer=append(m.modalBuffer,[]rune(msg.Text)...)};return m,nil
    }
   }
   switch key {
   case "esc":m.modal="";m.modalItems=nil;m.modalValues=nil
   case "up","ctrl+p":if m.modalIndex>0 {m.modalIndex--}
   case "down","ctrl+n":if m.modalIndex+1<len(m.modalItems) {m.modalIndex++}
   case "enter":
    if m.modalIndex<len(m.modalValues)&&(m.host!=nil||m.modal=="slash"||m.modal=="skills"||m.modal=="skills_browse"||m.modal=="files") {
     chosen:=m.modalValues[m.modalIndex]
     switch m.modal {
     case "models":m.modal="";m.modalValues=nil;return m,request(m.host,"switch_model",map[string]any{"slot_id":chosen})
     case "sessions":m.modal="";m.modalValues=nil;return m,request(m.host,"switch_session",map[string]any{"id":chosen})
     case "providers":
      methods:=m.providerMethods[chosen]
      if len(methods)>1 {m.pendingProvider=chosen;m.modal="login_methods";m.modalItems=append([]string(nil),methods...);m.modalValues=append([]string(nil),methods...);m.modalIndex=0;return m,nil}
      method:="";if len(methods)==1 {method=methods[0]}
      m.modal="";m.modalValues=nil;return m,request(m.host,"login",map[string]any{"provider":chosen,"method":method})
     case "login_methods":provider:=m.pendingProvider;m.pendingProvider="";m.modal="";m.modalValues=nil;return m,request(m.host,"login",map[string]any{"provider":provider,"method":chosen})
     case "efforts":m.modal="";m.modalValues=nil;return m,request(m.host,"select_effort",map[string]any{"effort":chosen})
     case "rewind":
      index,err:=strconv.Atoi(chosen);m.modal="";m.modalValues=nil
      if err!=nil {m.err="invalid rewind index";return m,nil}
      return m,request(m.host,"rewind_apply",map[string]any{"message_index":index})
     case "slash":
      m.textarea.SetValue(slashInsertion(chosen));m.textarea.Focus();m.modal="";m.modalValues=nil;m.completionToken="";return m,nil
     case "skills_browse":
      m.modal="";m.modalItems=nil;m.modalValues=nil;return m,nil
     case "files","skills":
      symbol:="@";if m.modal=="skills" {symbol="$"}
      inserted:=m.completionPrefix+symbol+chosen
      if !strings.HasSuffix(chosen,"/") {inserted+=" "}
      m.textarea.SetValue(inserted);m.textarea.Focus();m.modal="";m.modalValues=nil;m.completionToken="";return m,nil
     }
    }
    m.modal="";m.modalValues=nil
   }
   return m,nil
  }
  switch key {
  case "tab":
   value:=m.textarea.Value()
   if strings.HasPrefix(value,"/") {
    choices:=slashSuggestions(value)
    if len(choices)>0 {
     m.modal="slash";m.modalIndex=0;m.modalItems=nil;m.modalValues=nil
     for _,choice:=range choices {m.modalItems=append(m.modalItems,choice.label);m.modalValues=append(m.modalValues,choice.insert)}
    }
    return m,nil
   }
   if m.host==nil {return m,nil}
   at:=strings.LastIndexAny(value,"@$")
   if at>=0 && !strings.ContainsAny(value[at:]," \t\n") {
    m.completionPrefix=value[:at]
    m.completionToken=value[at:]
    if value[at]=='@' {return m,request(m.host,"file_search",map[string]any{"q":value[at+1:]})}
    return m,request(m.host,"skills",map[string]any{})
   }
   return m,nil
  case "ctrl+o":m.showTools=!m.showTools;return m,nil
  case "ctrl+t":m.showThinking=!m.showThinking;return m,nil
  case "esc":
   if m.host!=nil&&m.running {m.lastEscape=time.Time{};return m,request(m.host,"turn_abort",map[string]any{})}
   if m.host!=nil&&m.authID!="" {
    m.status="cancelling authentication"
    return m,request(m.host,"login_cancel",map[string]any{"auth_id":m.authID})
   }
   if m.host!=nil&&time.Since(m.lastEscape)<450*time.Millisecond {m.lastEscape=time.Time{};return m,request(m.host,"rewind_points",map[string]any{})}
   m.lastEscape=time.Now();return m,nil
  case "pgup","pageup":m.scrollTranscript(-max(1,m.viewport.Height()/2));return m,nil
  case "pgdown","pagedown":m.scrollTranscript(max(1,m.viewport.Height()/2));return m,nil
  case "enter":
   value:=strings.TrimSpace(m.textarea.Value())
   if value=="" {return m,nil}
   if m.host==nil {m.err="Posoco is not connected";return m,nil}
   m.textarea.Reset()
   if strings.HasPrefix(value,"/") {return m,m.command(value)}
   m.transcript=append(m.transcript,"> "+value)
   if m.running {
    m.followups=append(m.followups,value)
    m.status=fmt.Sprintf("queued %d follow-up(s)",len(m.followups))
    m.refreshTranscript();return m,nil
   }
   m.running=true;m.refreshTranscript()
   return m,request(m.host,"turn_start",map[string]any{"prompt":value,"session_id":m.session})
  case "shift+enter","ctrl+j":m.textarea.InsertString("\n");return m,nil
  }
 }
 var cmd tea.Cmd
 m.textarea,cmd=m.textarea.Update(message)
 return m,cmd
}

// dismissUI consumes a completion/cancellation event only for the indicated
// request. The native runtime can finish a UiPort coroutine independently of
// the focused Bubble Tea picker, so stale dismissals must not close the next
// question (or an unrelated model/command selector).
func (m *model) dismissUI(id string) {
 if id=="" {return}
 if id==m.modalRequestID {
  m.modal="";m.modalRequestID="";m.modalItems=nil;m.modalValues=nil
  m.modalBuffer=nil;m.modalPrompt="";m.modalIndex=0
  if len(m.pendingUI)>0 {
   next:=m.pendingUI[0];m.pendingUI=m.pendingUI[1:];m.activateUI(next)
   m.status="waiting for user input"
  } else {
   m.status="ready"
  }
  return
 }
 for i,req:=range m.pendingUI {
  if req.id==id {
   m.pendingUI=append(m.pendingUI[:i:i],m.pendingUI[i+1:]...)
   return
  }
 }
}

func (m *model) answerModal(answer map[string]any) tea.Cmd {
 id:=m.modalRequestID
 answer["request_id"]=id
 m.modal="";m.modalRequestID="";m.modalItems=nil;m.modalBuffer=nil;m.modalPrompt=""
 if len(m.pendingUI)>0 {next:=m.pendingUI[0];m.pendingUI=m.pendingUI[1:];m.activateUI(next)}
 return request(m.host,"ui_response",answer)
}

func (m *model) activateUI(req uiPrompt) {
 m.modalRequestID=req.id;m.modal=req.kind;m.modalPrompt=req.prompt;m.modalIndex=0
 m.modalItems=append([]string(nil),req.options...);m.modalBuffer=nil
 if req.kind=="confirm" {m.modalItems=[]string{"Yes","No"}}
 if req.kind=="input"&&len(req.defaultValue)>0 {
  var text string;if json.Unmarshal(req.defaultValue,&text)==nil {m.modalBuffer=[]rune(text)}
 }
}

func (m *model) command(value string) tea.Cmd {
 parts:=strings.Fields(value)
 switch parts[0] {
 case "/model":m.nextPicker="models";return request(m.host,"models",map[string]any{})
 case "/effort":if len(parts)>1 {return request(m.host,"select_effort",map[string]any{"effort":parts[1]})};m.nextPicker="efforts";return request(m.host,"models",map[string]any{})
 case "/new":return request(m.host,"switch_session",map[string]any{})
 case "/login":if len(parts)>1 {method:="";if len(parts)>2 {method=parts[2]};return request(m.host,"login",map[string]any{"provider":parts[1],"method":method})};return request(m.host,"providers",map[string]any{})
 case "/logout":if len(parts)>1 {return request(m.host,"logout",map[string]any{"provider":parts[1]})}
 case "/sessions":return request(m.host,"sessions",map[string]any{})
 case "/rewind":return request(m.host,"rewind_points",map[string]any{})
 case "/skills":return requestAs(m.host,"skills_browse","skills",map[string]any{})
 case "/compact":return request(m.host,"session_compact",map[string]any{})
 case "/find":
  m.findTranscript(strings.TrimSpace(strings.TrimPrefix(value,"/find")))
  return nil
 case "/find-next":
  m.navigateTranscriptSearch(false)
  return nil
 case "/find-prev":
  m.navigateTranscriptSearch(true)
  return nil
 case "/copyhistory":
  text,err:=m.copyHistoryCommand(parts)
  if err!=nil {m.err=err.Error();return nil}
  return tea.SetClipboard(text)
 case "/permission":
  if len(parts)>1 {return request(m.host,"set_permission",map[string]any{"mode":parts[1]})}
 case "/help":return func() tea.Msg {return commandResult{name:"help",payload:json.RawMessage(`{"ok":true}`)}}
 }
 return func() tea.Msg {return commandResult{name:value,err:fmt.Errorf("command not available in this migration checkpoint")}}
}

// The EventHub carries tool results as text and auth.login outcomes as
// structured JSON. Decoding the entire event through a string "result" field
// rejected valid auth outcomes before the type switch even ran.
func toolResultText(raw json.RawMessage) string {
 if len(raw)==0||string(raw)=="null" {return ""}
 var value string
 if json.Unmarshal(raw,&value)==nil {return value}
 return string(raw)
}

func (m *model) applyEvent(e harness.Event) {
 var frame struct {
  Type string `json:"type"`
  Text string `json:"text"`
  Delta string `json:"delta"`
  Token string `json:"token"`
  Message string `json:"message"`
  ToolName string `json:"tool_name"`
  ToolCallID string `json:"tool_call_id"`
  Result json.RawMessage `json:"result"`
  IsError bool `json:"is_error"`
  Title string `json:"title"`
  Entries []struct {Key string `json:"key"`;Value string `json:"value"`} `json:"entries"`
  SessionID string `json:"session_id"`
  RequestID string `json:"request_id"`
  Kind string `json:"kind"`
  Prompt string `json:"prompt"`
  Options []string `json:"options"`
  Slot string `json:"slot"`
  Lines []string `json:"lines"`
  Default json.RawMessage `json:"default"`
  Busy bool `json:"busy"`
  From string `json:"from"`
  To string `json:"to"`
 }
 if json.Unmarshal(e.Raw,&frame)!=nil {return}
 if frame.SessionID!="" {
  if m.session=="" {m.session=frame.SessionID}
  // Do not let another running session mutate the visible transcript.
  if frame.SessionID!=m.session && frame.Type!="auth.login" && frame.Type!="auth.cancelled" {return}
 }
 switch frame.Type {
 case "turn.accepted","turn.started":m.running=true;m.status="working"
 case "assistant.text_delta":
  delta:=frame.Delta
  if delta=="" {delta=frame.Text};if delta=="" {delta=frame.Token}
  m.streaming+=delta
 case "assistant.reasoning_delta":
  delta:=frame.Delta
  if delta=="" {delta=frame.Text};if delta=="" {delta=frame.Token}
  m.reasoning+=delta
 case "tool.started":
  if m.toolIndex==nil {m.toolIndex=make(map[string]int)}
  if frame.ToolCallID!="" {m.toolIndex[frame.ToolCallID]=len(m.transcript)}
  m.transcript=append(m.transcript,"• "+frame.ToolName+" …")
 case "tool.completed":
  marker:="✓";if frame.IsError {marker="✗"}
  if at,ok:=m.toolIndex[frame.ToolCallID];ok&&at<len(m.transcript) {m.transcript[at]="• "+frame.ToolName+" "+marker}
  if rendered:=toolResultText(frame.Result);rendered!="" {
   if m.showTools {m.transcript=append(m.transcript,rendered)} else if at,ok:=m.toolIndex[frame.ToolCallID];ok {m.addHiddenSource(at,rendered)}
  }
 case "turn.completed":
  text:=m.streaming;if text=="" {text=frame.Text}
  if text!="" {m.appendAssistant(text)}
  if len(m.reasoning)>0 {
   if m.showThinking {m.transcript=append(m.transcript,"Thinking: "+m.reasoning)} else {m.addHiddenSource(max(0,len(m.transcript)-1),"Thinking: "+m.reasoning)}
  }
  m.streaming="";m.reasoning="";m.running=false;m.status="ready"
 case "turn.failed":
  m.transcript=append(m.transcript,"Error: "+frame.Message)
  m.streaming="";m.reasoning="";m.running=false;m.status="failed"
 case "session.redirect":if frame.From==m.session&&frame.To!="" {m.session=frame.To};m.status="session redirected"
 case "session.snapshot":m.running=frame.Busy
 case "ui.request":
  if frame.RequestID=="" {m.err="ui.request missing request_id";return}
  prompt:=uiPrompt{id:frame.RequestID,kind:frame.Kind,prompt:frame.Prompt,options:frame.Options,defaultValue:frame.Default}
  if m.modalRequestID!="" {m.pendingUI=append(m.pendingUI,prompt)} else {m.activateUI(prompt)}
  m.status="waiting for user input"
 case "ui.dismiss":
  m.dismissUI(frame.RequestID)
 case "auth.cancelled":
  var payload struct{AuthID string `json:"auth_id"`}
  if json.Unmarshal(e.Raw,&payload)==nil && payload.AuthID!="" && payload.AuthID==m.authID {
   m.authID=""
   m.err=""
   m.status="authentication cancelled"
  }
 case "auth.login":
  // Login outcomes are provider-neutral and intentionally contain no
  // credentials. Never dump the raw result into the transcript or errors.
  var result struct {
   Type string `json:"type"`
   Feedback string `json:"feedback"`
   Error string `json:"error"`
  }
  var payload struct {Provider string `json:"provider"`; AuthID string `json:"auth_id"`; Result json.RawMessage `json:"result"`}
  // A cancelled or replaced task must not mutate the visible login state.
  if payloadErr:=json.Unmarshal(e.Raw,&payload);payloadErr!=nil {return}
  if payload.AuthID!="" && payload.AuthID!=m.authID {return}
  m.authID=""
  if json.Unmarshal(payload.Result,&result)!=nil {
   m.err="authentication returned an invalid result";m.status="authentication failed"
  } else if result.Type=="success" {
   m.err=""
   m.status="signed in to "+payload.Provider
  } else {
   m.status="authentication failed"
   // Do not echo arbitrary provider diagnostics: a provider may include the
   // submitted API key in its error detail.
   m.err="login failed for "+payload.Provider
  }
 case "ui.render":
  text:=frame.Text
  if len(frame.Lines)>0 {text=strings.Join(frame.Lines,"\n")}
  if len(frame.Entries)>0 {for _,entry:=range frame.Entries {text+=" "+entry.Key+"="+entry.Value}}
  slot:=strings.ToLower(frame.Slot)
  if strings.Contains(slot,"status") {if strings.TrimSpace(text)!="" {m.status=text}}
  if strings.Contains(slot,"notice")||strings.Contains(slot,"widget") {
   if frame.Title!="" {text=frame.Title+": "+text}
   if strings.TrimSpace(text)!="" {m.transcript=append(m.transcript,text)}
  }
 }
}

func (m *model) appendAssistant(text string) {
 if m.markdownRaw==nil {m.markdownRaw=make(map[int]string)}
 idx:=len(m.transcript);m.transcript=append(m.transcript,text);m.markdownRaw[idx]=text
}

func (m *model) resize() {
 width:=max(20,m.width-2)
 m.textarea.SetWidth(width)
 if renderer,err:=glamour.NewTermRenderer(glamour.WithWordWrap(width));err==nil {m.markdownRenderer=renderer;m.markdownCache=nil}
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
  if m.modalPrompt!="" {content.WriteString(m.modalPrompt+"\n")} else {content.WriteString("Choose (↑/↓, Enter, Esc):\n")}
  if m.modal=="input" {content.WriteString("> "+string(m.modalBuffer)+"_\n")}
  if m.modal=="secret" {content.WriteString("> "+strings.Repeat("•",len(m.modalBuffer))+"_\n")}
  for i,s:=range m.modalItems {if i==m.modalIndex {content.WriteString("▶ ")} else {content.WriteString("  ")};content.WriteString(s+"\n")}
 } else {
  content.WriteString(m.viewport.View()+"\n")
  content.WriteString(m.textarea.View()+"\n")
 }
 content.WriteString(" "+m.status+"  |  Enter send  Shift+Enter newline  Esc interrupt  Ctrl+C quit")
 if m.err!="" {content.WriteString("\n"+lipgloss.NewStyle().Foreground(lipgloss.Color("#D64C4C")).Render(m.err))}
 view:=tea.NewView(content.String())
 view.AltScreen=true
 view.MouseMode=tea.MouseModeCellMotion
 if m.modal=="" {if cursor:=m.textarea.Cursor();cursor!=nil {cursor.Y+=m.viewport.Height()+2;view.Cursor=cursor}}
 return view
}
var version="0.11.0"

func main() {
 for _,arg:=range os.Args[1:] {
  if arg=="--version"||arg=="-version" {fmt.Println("cetas "+version);return}
  if arg=="--help"||arg=="-h" {fmt.Println("Cetas native terminal\nUsage: cetas [--version|--help]\nInside the UI: /help");return}
 }
 p:=tea.NewProgram(newModel())
 result,err:=p.Run()
 if state,ok:=result.(model);ok && state.host!=nil {
  ctx,cancel:=context.WithTimeout(context.Background(),15*time.Second)
  if closeErr:=state.host.Close(ctx);closeErr!=nil {fmt.Fprintln(os.Stderr,"shutdown:",closeErr)}
  cancel()
 }
 if err!=nil {fmt.Fprintln(os.Stderr,err);os.Exit(1)}
}
