package localipc

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

const Protocol = "cetas.local/1"
const MaxFrameSize = 4 << 20

var ErrProtocol = errors.New("invalid Cetas local IPC protocol")
var ErrFrameTooLarge = errors.New("Cetas local IPC frame exceeds 4 MiB")

// Envelope carries transport facts only. Args, Result, and Event remain
// opaque JSON owned by the existing Cetas command/EventHub protocols.
type Envelope struct {
	Type             string          `json:"type"`
	Protocol         string          `json:"protocol,omitempty"`
	Host             string          `json:"host,omitempty"`
	HostVersion      string          `json:"host_version,omitempty"`
	ClientInstanceID string          `json:"client_instance_id,omitempty"`
	OwnerInstanceID  string          `json:"owner_instance_id,omitempty"`
	RuntimeEpoch     string          `json:"runtime_epoch,omitempty"`
	Capabilities     []string        `json:"capabilities,omitempty"`
	Required         []string        `json:"required,omitempty"`
	MaxFrameSize     int             `json:"max_frame_size,omitempty"`
	SurfaceID        string          `json:"surface_id,omitempty"`
	RequestID        string          `json:"request_id,omitempty"`
	OperationID      string          `json:"operation_id,omitempty"`
	Command          string          `json:"command,omitempty"`
	Args             json.RawMessage `json:"args,omitempty"`
	Result           json.RawMessage `json:"result,omitempty"`
	Event            json.RawMessage `json:"event,omitempty"`
	Error            string          `json:"error,omitempty"`
}

// Codec reads and writes strict newline-delimited JSON frames from a stream.
// It rejects unterminated, oversized and unknown envelopes; the caller must
// close the connection on any framing error. Concurrent writes are serialized
// so separate response/event producers cannot interleave their bytes.
type Codec struct {
	reader *bufio.Reader
	writer io.Writer
	writeMu sync.Mutex
}

func NewCodec(r io.Reader, w io.Writer) *Codec {
	return &Codec{reader: bufio.NewReaderSize(r, 64*1024), writer: w}
}

func (c *Codec) Read() (Envelope, error) {
	var line []byte
	for {
		chunk, err := c.reader.ReadSlice('\n')
		if len(line)+len(chunk) > MaxFrameSize+1 {
			return Envelope{}, ErrFrameTooLarge
		}
		line = append(line, chunk...)
		switch {
		case err == nil:
			if len(line) <= 1 || line[len(line)-1] != '\n' {
				return Envelope{}, ErrProtocol
			}
			var out Envelope
			if !json.Valid(line[:len(line)-1]) || line[0] != '{' {
				return Envelope{}, fmt.Errorf("%w: expected JSON object", ErrProtocol)
			}
			if json.Unmarshal(line[:len(line)-1], &out) != nil || !validType(out.Type) {
				return Envelope{}, fmt.Errorf("%w: unsupported or malformed envelope", ErrProtocol)
			}
			return out, nil
		case errors.Is(err, bufio.ErrBufferFull):
			continue
		case errors.Is(err, io.EOF) && len(line) == 0:
			return Envelope{}, io.EOF
		case errors.Is(err, io.EOF):
			return Envelope{}, fmt.Errorf("%w: unterminated frame", ErrProtocol)
		default:
			return Envelope{}, err
		}
	}
}

func validType(kind string) bool {
	switch kind {
	case "hello", "welcome", "reject", "request", "response", "event", "ping", "pong", "goodbye":
		return true
	default:
		return false
	}
}

func (c *Codec) Write(frame Envelope) error {
	if !validType(frame.Type) {
		return fmt.Errorf("%w: unsupported frame type %q", ErrProtocol, frame.Type)
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("%w: marshal: %v", ErrProtocol, err)
	}
	if len(data) > MaxFrameSize {
		return ErrFrameTooLarge
	}
	data = append(data, '\n')
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	for len(data) > 0 {
		n, err := c.writer.Write(data)
		if err != nil {
			return err
		}
		if n <= 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}
