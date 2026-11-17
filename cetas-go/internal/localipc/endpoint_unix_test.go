//go:build !windows

package localipc

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestListenLocalRequiresLeaseAndRestrictsSocket(t *testing.T){
	if _,err:=ListenLocal(nil);err==nil{t.Fatal("listener without owner lease")}
	home:=t.TempDir()
	lease,err:=Acquire(home)
	if err!=nil{t.Fatal(err)}
	defer lease.Close()
	listener,err:=ListenLocal(lease)
	if err!=nil{t.Fatal(err)}
	defer listener.Close()
	path:=filepath.Join(home,".cetas","ipc",socketName)
	st,err:=os.Lstat(path)
	if err!=nil{t.Fatal(err)}
	if st.Mode()&os.ModeSocket==0 || st.Mode().Perm()&0077!=0 {t.Fatalf("socket mode: %s",st.Mode())}
	if second,err:=ListenLocal(lease);second!=nil||!errors.Is(err,ErrEndpointActive){t.Fatalf("competing endpoint: %v %v",second,err)}
	client,err:=DialLocal(context.Background(),home)
	if err!=nil{t.Fatal(err)}
	defer client.Close()
	peer,err:=listener.Accept()
	if err!=nil{t.Fatal(err)}
	defer peer.Close()
}

func TestListenLocalReclaimsOnlyVerifiedStaleSocket(t *testing.T){
	home:=t.TempDir()
	lease,err:=Acquire(home)
	if err!=nil{t.Fatal(err)}
	defer lease.Close()
	path:=filepath.Join(home,".cetas","ipc",socketName)
	stale,err:=net.ListenUnix("unix",&net.UnixAddr{Name:path,Net:"unix"})
	if err!=nil{t.Fatal(err)}
	stale.SetUnlinkOnClose(false)
	if err:=stale.Close();err!=nil{t.Fatal(err)}
	listener,err:=ListenLocal(lease)
	if err!=nil{t.Fatal(err)}
	if err:=listener.Close();err!=nil{t.Fatal(err)}
	if _,err:=os.Lstat(path);!errors.Is(err,os.ErrNotExist){t.Fatalf("socket still present: %v",err)}
}

func TestListenLocalRejectsNonSocketPath(t *testing.T){
	home:=t.TempDir()
	lease,err:=Acquire(home)
	if err!=nil{t.Fatal(err)}
	defer lease.Close()
	path:=filepath.Join(home,".cetas","ipc",socketName)
	if err:=os.WriteFile(path,[]byte("do not remove"),0600);err!=nil{t.Fatal(err)}
	if listener,err:=ListenLocal(lease);listener!=nil||err==nil{t.Fatalf("unsafe endpoint admitted: %v %v",listener,err)}
	data,err:=os.ReadFile(path);if err!=nil||string(data)!="do not remove"{t.Fatalf("endpoint overwritten: %q %v",data,err)}
}
