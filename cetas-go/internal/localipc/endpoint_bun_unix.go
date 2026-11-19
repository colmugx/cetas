//go:build !windows

package localipc

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// BunOwnerAvailable examines only the protected per-user socket path;
// it never starts a runtime or creates on-disk state.
func BunOwnerAvailable(home string) bool {
	path, err := bunOwnerPath(home)
	if err != nil { return false }
	dir := filepath.Dir(path)
	if err := checkDirectory(dir, true); err != nil { return false }
	info, err := os.Lstat(path)
	return err == nil && info.Mode()&os.ModeSocket != 0 && info.Mode().Perm()&0077 == 0
}

func bunOwnerPath(home string) (string,error) {
	root,err:=filepath.Abs(home)
	if err!=nil{return "",err}
	root,err=filepath.EvalSymlinks(root)
	if err!=nil{return "",err}
	digest:=sha256.Sum256([]byte(root))
	return filepath.Join("/tmp",fmt.Sprintf("cetas-bun-%d-%x",os.Geteuid(),digest[:12]),"owner.sock"),nil
}

// DialBunOwner only connects to a verified same-user Unix socket. The Bun
// service does not publish a Windows pipe without an OS-restricted ACL.
func DialBunOwner(ctx context.Context,home string)(net.Conn,error) {
	if !BunOwnerAvailable(home) {
		return nil,errors.New("no protected Bun Session owner endpoint")
	}
	path,err:=bunOwnerPath(home)
	if err!=nil{return nil,err}
	return (&net.Dialer{}).DialContext(ctx,"unix",path)
}
