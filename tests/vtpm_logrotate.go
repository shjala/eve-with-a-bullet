// Copyright (c) 2026 Zededa, Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

const (
	vtpmdSockPath = "/run/swtpm/vtpmd.ctrl.sock"
	swtpmPidFmt   = "/run/swtpm/%s.pid"
	swtpmCtrlFmt  = "/run/swtpm/%s.ctrl.sock"
	swtpmStateDir = "/persist/swtpm/tpm-state-%s"
	swtpmLogFmt   = "/persist/swtpm/tpm-state-%s/swtpm.log"
)

func init() {
	register(
		"vtpm-log-created",
		"Launch a vtpm instance via vtpmd and verify swtpm.log is created",
		TestVtpmLogCreated,
	)
	register(
		"vtpm-log-rotation",
		"Verify log rotation is bounded: count stays capped, active log doesn't grow forever",
		TestVtpmLogRotation,
	)
}

// newUUID generates a random RFC-4122 version-4 UUID string without
// importing an external package.
func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("newUUID: rand.Read failed: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant bits
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// vtpmdHTTPClient returns an http.Client that talks over the vtpmd Unix socket.
func vtpmdHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", vtpmdSockPath)
			},
		},
	}
}

// vtpmdRequest sends a GET request to the vtpmd control socket.
// endpoint is one of "launch", "terminate", or "purge".
func vtpmdRequest(endpoint, uuid string) error {
	client := vtpmdHTTPClient()
	url := fmt.Sprintf("http://localhost/%s?id=%s", endpoint, uuid)
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("vtpmd %s: %w", endpoint, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("vtpmd %s returned HTTP %d", endpoint, resp.StatusCode)
	}
	return nil
}

// waitForPath polls until path exists or timeout is reached.
func waitForPath(path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s", path)
}

// saveLogOnFailure copies logPath to /persist/test-failures/<testName>-<timestamp>.log
func saveLogOnFailure(testName, logPath string) {
	ts := time.Now().Format("2006-01-02T15-04-05")
	dest := fmt.Sprintf("/persist/test-failures/%s-%s.log", testName, ts)
	if err := os.MkdirAll("/persist/test-failures", 0755); err != nil {
		fmt.Printf("  [failure-log] could not create dir: %v\n", err)
		return
	}
	src, err := os.Open(logPath)
	if err != nil {
		fmt.Printf("  [failure-log] could not open %s: %v\n", logPath, err)
		return
	}
	defer src.Close()
	dst, err := os.Create(dest)
	if err != nil {
		fmt.Printf("  [failure-log] could not create %s: %v\n", dest, err)
		return
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		fmt.Printf("  [failure-log] copy failed: %v\n", err)
		return
	}
	fmt.Printf("  [failure-log] saved to %s\n", dest)
}

type swtpmCtrl struct {
	conn net.Conn
}

func newSwtpmCtrl(ctrlSock string) (*swtpmCtrl, error) {
	conn, err := net.DialTimeout("unix", ctrlSock, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("connect to swtpm ctrl socket %s: %w", ctrlSock, err)
	}
	return &swtpmCtrl{conn: conn}, nil
}

func (c *swtpmCtrl) Close() { c.conn.Close() }

func (c *swtpmCtrl) sendCmd(payload []byte, respLen int) ([]byte, error) {
	if _, err := c.conn.Write(payload); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}
	buf := make([]byte, respLen)
	if _, err := io.ReadFull(c.conn, buf); err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	return buf, nil
}

// cmdInit sends CMD_INIT (0x02) with flags=0. TPM must be uninitialized.
// Response: 4-byte ptm_res.
func (c *swtpmCtrl) cmdInit() error {
	b := make([]byte, 8)
	binary.BigEndian.PutUint32(b[0:4], 0x00000002) // CMD_INIT
	binary.BigEndian.PutUint32(b[4:8], 0x00000000) // init_flags
	resp, err := c.sendCmd(b, 4)
	if err != nil {
		return fmt.Errorf("CMD_INIT: %w", err)
	}
	if rc := binary.BigEndian.Uint32(resp); rc != 0 {
		return fmt.Errorf("CMD_INIT: error code 0x%08x", rc)
	}
	return nil
}

// cmdGetCapability sends CMD_GET_CAPABILITY (0x01). Works in any state.
// Response: ptm_res (4) + caps (4).
func (c *swtpmCtrl) cmdGetCapability() error {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, 0x00000001)
	resp, err := c.sendCmd(b, 8)
	if err != nil {
		return fmt.Errorf("CMD_GET_CAPABILITY: %w", err)
	}
	if rc := binary.BigEndian.Uint32(resp[0:4]); rc != 0 {
		return fmt.Errorf("CMD_GET_CAPABILITY: error code 0x%08x", rc)
	}
	return nil
}

// countRotatedLogs returns the number of rotated log files in the state directory.
// Rotated logs are named swtpm.log.1, swtpm.log.2, etc., optionally compressed.
func countRotatedLogs(stateDir string) int {
	count := 0
	for i := 1; i <= 100; i++ {
		// Check for both compressed and uncompressed versions
		if _, err := os.Stat(fmt.Sprintf("%s/swtpm.log.%d", stateDir, i)); err == nil {
			count++
		} else if _, err := os.Stat(fmt.Sprintf("%s/swtpm.log.%d.gz", stateDir, i)); err == nil {
			count++
		} else {
			break
		}
	}
	return count
}

// ── tests ────────────────────────────────────────────────────────────────────

// TestVtpmLogCreated launches a vtpm instance through vtpmd, sends CMD_INIT to
// the resulting swtpm control socket, and verifies that swtpm.log is created
// with content.
func TestVtpmLogCreated() error {
	if _, err := os.Stat(vtpmdSockPath); err != nil {
		return fmt.Errorf("vtpmd socket not found at %s (is this running inside EVE?): %w",
			vtpmdSockPath, err)
	}

	uuid := newUUID()
	pidPath := fmt.Sprintf(swtpmPidFmt, uuid)
	ctrlPath := fmt.Sprintf(swtpmCtrlFmt, uuid)
	logPath := fmt.Sprintf(swtpmLogFmt, uuid)

	var testErr error
	defer func() {
		if testErr != nil {
			saveLogOnFailure("vtpm-log-created", logPath)
		}
		if err := vtpmdRequest("purge", uuid); err != nil {
			fmt.Printf("  warn: purge failed: %v\n", err)
		}
	}()

	fmt.Printf("  launching swtpm instance %s\n", uuid)
	if testErr = vtpmdRequest("launch", uuid); testErr != nil {
		return testErr
	}

	fmt.Printf("  waiting for pid file at %s\n", pidPath)
	if testErr = waitForPath(pidPath, 10*time.Second); testErr != nil {
		return testErr
	}

	fmt.Printf("  waiting for log file at %s\n", logPath)
	if testErr = waitForPath(logPath, 5*time.Second); testErr != nil {
		return testErr
	}

	fmt.Printf("  connecting to ctrl socket %s\n", ctrlPath)
	ctrl, err := newSwtpmCtrl(ctrlPath)
	if err != nil {
		testErr = err
		return testErr
	}
	defer ctrl.Close()

	fmt.Printf("  sending CMD_INIT\n")
	if testErr = ctrl.cmdInit(); testErr != nil {
		return testErr
	}

	// Give swtpm a moment to flush buffered log output.
	time.Sleep(500 * time.Millisecond)

	info, err := os.Stat(logPath)
	if err != nil {
		testErr = fmt.Errorf("log file missing after CMD_INIT: %w", err)
		return testErr
	}
	if info.Size() == 0 {
		testErr = fmt.Errorf("log file exists but is empty after CMD_INIT")
		return testErr
	}

	fmt.Printf("  swtpm.log created with %d bytes\n", info.Size())
	return nil
}

// TestVtpmLogRotation launches a vtpm instance, initializes the TPM, then
// drives it with real control-channel operations over a single persistent
// connection to bulk-generate log output for logrotate verification.
//
// After the expected number of rotated logs appear, the test continues
// spamming to confirm that the rotation count stays capped and the active
// log file remains bounded in size.
func TestVtpmLogRotation() error {
	if _, err := os.Stat(vtpmdSockPath); err != nil {
		return fmt.Errorf("vtpmd socket not found at %s (is this running inside EVE?): %w",
			vtpmdSockPath, err)
	}

	uuid := newUUID()
	ctrlPath := fmt.Sprintf(swtpmCtrlFmt, uuid)
	logPath := fmt.Sprintf(swtpmLogFmt, uuid)
	stateDir := fmt.Sprintf(swtpmStateDir, uuid)

	var testErr error
	defer func() {
		if testErr != nil {
			saveLogOnFailure("vtpm-log-rotation", logPath)
		}
		if err := vtpmdRequest("purge", uuid); err != nil {
			fmt.Printf("  warn: purge failed: %v\n", err)
		}
	}()

	fmt.Printf("  launching swtpm instance %s\n", uuid)
	if testErr = vtpmdRequest("launch", uuid); testErr != nil {
		return testErr
	}

	if testErr = waitForPath(logPath, 10*time.Second); testErr != nil {
		return testErr
	}

	fmt.Printf("  connecting to ctrl socket %s\n", ctrlPath)
	ctrl, err := newSwtpmCtrl(ctrlPath)
	if err != nil {
		testErr = err
		return testErr
	}
	defer ctrl.Close()

	fmt.Printf("  initializing TPM...\n")
	if testErr = ctrl.cmdInit(); testErr != nil {
		return testErr
	}

	const maxRotatedLogs = 3

	// Phase 1: spam until the expected rotated logs appear.
	fmt.Printf("  phase 1: spamming CMD_GET_CAPABILITY until %d rotated logs appear...\n", maxRotatedLogs)
	for {
		if err := ctrl.cmdGetCapability(); err != nil {
			testErr = err
			return testErr
		}
		if countRotatedLogs(stateDir) >= maxRotatedLogs {
			fmt.Printf("  found %d rotated logs\n", maxRotatedLogs)
			break
		}
	}

	// Phase 2: keep spamming and verify rotation count stays capped and the
	// active log never grows unbounded. We drive enough traffic to trigger
	// several more rotations.
	const extraRotationCycles = 3
	fmt.Printf("  phase 2: continuing to spam for ~%d more rotation cycles...\n", extraRotationCycles)

	// Record log size at start of phase 2 to detect when a rotation cycle completes.
	cyclesSeen := 0
	prevSize := int64(0)
	for {
		if err := ctrl.cmdGetCapability(); err != nil {
			testErr = err
			return testErr
		}

		info, err := os.Stat(logPath)
		if err != nil {
			testErr = fmt.Errorf("swtpm.log disappeared: %w", err)
			return testErr
		}
		curSize := info.Size()

		// A size drop means the log was just truncated (rotated).
		if curSize < prevSize {
			cyclesSeen++
		}
		prevSize = curSize

		// Check invariants on every iteration.
		rotated := countRotatedLogs(stateDir)
		if rotated > maxRotatedLogs {
			testErr = fmt.Errorf("rotated log count exceeded cap: got %d, max %d", rotated, maxRotatedLogs)
			return testErr
		}

		if cyclesSeen >= extraRotationCycles {
			break
		}
	}

	// Final check.
	rotated := countRotatedLogs(stateDir)
	if rotated > maxRotatedLogs {
		testErr = fmt.Errorf("final check: rotated log count %d exceeds cap %d", rotated, maxRotatedLogs)
		return testErr
	}
	fmt.Printf("  rotated log count after extra cycles: %d (cap %d) ✓\n", rotated, maxRotatedLogs)
	fmt.Printf("\n  Log rotation is correctly bounded.\n")
	return nil
}
