//go:build windows

package localipc

import (
	"context"
	"errors"
	"net"
)

// Bun does not yet publish a Windows named pipe with verified owner-only ACL.
// It must never fall back to an unprotected pipe or TCP.
func BunOwnerAvailable(string) bool { return false }
func DialBunOwner(context.Context,string)(net.Conn,error){
	return nil,errors.New("protected Bun Session owner pipe not available on Windows")
}
