package main

import (
 "encoding/json"
 "strings"
 "testing"
 tea "charm.land/bubbletea/v2"
)

func TestBootstrapProviderPickerWithEmptySession(t *testing.T) {
 m:=newModel()
 m.needsSetup=true
 m.host=&testHost{}
 updated,_:=m.Update(commandResult{name:"providers",payload:json.RawMessage(`{"providers":[{"id":"openai","name":"openai","signed_in":false,"methods":["api_key"]},{"id":"kimi","name":"kimi","signed_in":false,"methods":["api_key","oauth"]}]}`)})
 model:=updated.(model)
 if model.modal!="providers"||len(model.modalValues)!=2||!strings.Contains(model.modalPrompt,"First-run") {
  t.Fatalf("setup provider picker missing: modal=%q values=%#v prompt=%q",model.modal,model.modalValues,model.modalPrompt)
 }
 if model.session!="" {t.Fatal("setup must not fabricate a session before Agent composition")}
 updated,cmd:=model.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 model=updated.(model)
 if cmd==nil||model.modal!="" {t.Fatalf("provider selection did not launch login: %q",model.modal)}
 if result,ok:=cmd().(commandResult);!ok||result.name!="login" {
  t.Fatalf("unexpected setup command: %#v",result)
 }
}
func TestBootstrapUiCanAcceptSecretAndActivateRealSession(t *testing.T) {
 m:=newModel()
 m.host=&testHost{}
 m.needsSetup=true
 m.applyEvent(event(`{"type":"ui.request","request_id":"u-setup","kind":"secret","prompt":"API Key"}`))
 if m.modal!="secret"||m.modalRequestID!="u-setup" {t.Fatalf("setup credential request not shown: %#v",m)}
 m.modalBuffer=[]rune("private-token")
 if strings.Contains(m.View().Content,"private-token") {t.Fatal("secret appeared on PTY view")}
 updated,cmd:=m.Update(tea.KeyPressMsg{Code:tea.KeyEnter})
 m=updated.(model)
 if cmd==nil||m.modalRequestID!=""||len(m.modalBuffer)!=0 {t.Fatal("setup secret not retired after answer")}
 m.applyEvent(event(`{"type":"auth.login","auth_id":"","provider":"openai","result":{"type":"success","feedback":"ok"}}`))
 if !strings.Contains(m.status,"initializing Agent") {t.Fatalf("setup login was mistaken for fully-ready: %q",m.status)}
 m.applyEvent(event(`{"type":"infra.ready","snapshot":{"session_id":"real-session"}}`))
 if m.needsSetup||m.session!="real-session"||m.status!="ready" {t.Fatalf("bootstrap did not activate runtime: %#v",m)}
}
func TestBootstrapFailureIsVisibleWithoutSecretDisclosure(t *testing.T) {
 m:=newModel()
 m.needsSetup=true
 m.applyEvent(event(`{"type":"infra.setup_failed","detail":"private-key-should-not-be-displayed"}`))
 if !m.needsSetup||!strings.Contains(m.status,"incomplete") {t.Fatalf("setup failure was hidden: %q",m.status)}
 if strings.Contains(m.View().Content,"private-key-should-not-be-displayed") {t.Fatal("internal startup detail leaked into UI")}
}
