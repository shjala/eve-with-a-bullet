// Copyright (c) 2026 Zededa, Inc.
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

const (
	tpmDevPath         = "/dev/tpmrm0"
	encryptedMarkerFmt = "/persist/swtpm/%s.encrypted"
	swtpmStateFmt      = "/persist/swtpm/tpm-state-%s/tpm2-00.permall"
)

func init() {
	register(
		"vtpm-encrypted-state-no-sha256",
		"Launch vtpmd instance, verify encrypted state works and survives terminate+relaunch when SHA256 bank may be absent",
		TestVtpmEncryptedStateNoSHA256,
	)
}

// sha256BankAvailable probes the TPM chardev by sending TPM2_CC_PCR_Read for
// SHA256 bank PCR 0 and checks whether the response contains at least one
// digest. Returns false if the bank is absent or the device cannot be reached.
func sha256BankAvailable() bool {
	f, err := os.OpenFile(tpmDevPath, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	defer f.Close()

	// TPM2_CC_PCR_Read, one selection: SHA256 (0x000B), sizeofSelect=3, PCR 0.
	cmd := []byte{
		0x80, 0x01,             // TPM_ST_NO_SESSIONS
		0x00, 0x00, 0x00, 0x14, // size = 20
		0x00, 0x00, 0x01, 0x7E, // TPM2_CC_PCR_Read
		0x00, 0x00, 0x00, 0x01, // TPML_PCR_SELECTION.count = 1
		0x00, 0x0B,             // TPM_ALG_SHA256
		0x03,                   // sizeofSelect = 3
		0x01, 0x00, 0x00,       // PCR 0 selected
	}
	if _, err := f.Write(cmd); err != nil {
		return false
	}

	resp := make([]byte, 256)
	n, err := f.Read(resp)
	if err != nil || n < 10 {
		return false
	}

	// Response header: tag(2) + size(4) + rc(4). If rc != 0 the bank is absent.
	rc := binary.BigEndian.Uint32(resp[6:10])
	if rc != 0 {
		return false
	}

	// pcrUpdateCounter(4) + TPML_DIGEST.count(4) follow the PCR selection block.
	// A count > 0 means the bank returned at least one digest.
	if n < 30 {
		return false
	}
	digestCount := binary.BigEndian.Uint32(resp[26:30])
	return digestCount > 0
}

// waitForEncryptedMarker polls for the vtpmd encrypted-state marker file.
func waitForEncryptedMarker(uuid string, timeout time.Duration) error {
	path := fmt.Sprintf(encryptedMarkerFmt, uuid)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && string(data) == "Y" {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for encrypted marker at %s", fmt.Sprintf(encryptedMarkerFmt, uuid))
}

// dumpStateHeader reads the first 32 bytes of the swtpm persistent state file
// and prints them as a hex dump. Encrypted state starts with random-looking
// bytes; plaintext state begins with a recognisable libtpms magic header
// (e.g. "ls -" / 0x6c732d...).
func dumpStateHeader(uuid string) {
	path := fmt.Sprintf(swtpmStateFmt, uuid)
	f, err := os.Open(path)
	if err != nil {
		fmt.Printf("  [state] could not open %s: %v\n", path, err)
		return
	}
	defer f.Close()

	buf := make([]byte, 32)
	n, err := io.ReadAtLeast(f, buf, 1)
	if err != nil {
		fmt.Printf("  [state] read error: %v\n", err)
		return
	}
	buf = buf[:n]

	fmt.Printf("  [state] first %d bytes of tpm2-00.permall:\n", n)
	for i := 0; i < len(buf); i += 8 {
		end := i + 8
		if end > len(buf) {
			end = len(buf)
		}
		fmt.Printf("  [state]   %04x  ", i)
		for _, b := range buf[i:end] {
			fmt.Printf("%02x ", b)
		}
		fmt.Println()
	}
}

// probeSwtpm opens the swtpm control socket and sends CMD_GET_CAPABILITY to
// verify the instance is alive and responsive.
func probeSwtpm(ctrlSock string) error {
	conn, err := net.DialTimeout("unix", ctrlSock, 5*time.Second)
	if err != nil {
		return fmt.Errorf("connect to %s: %w", ctrlSock, err)
	}
	defer conn.Close()

	cmd := make([]byte, 4)
	binary.BigEndian.PutUint32(cmd, 0x00000001) // CMD_GET_CAPABILITY
	if _, err := conn.Write(cmd); err != nil {
		return fmt.Errorf("write CMD_GET_CAPABILITY: %w", err)
	}
	resp := make([]byte, 8)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return fmt.Errorf("read CMD_GET_CAPABILITY response: %w", err)
	}
	if rc := binary.BigEndian.Uint32(resp[0:4]); rc != 0 {
		return fmt.Errorf("CMD_GET_CAPABILITY returned error 0x%08x", rc)
	}
	return nil
}

// TestVtpmEncryptedStateNoSHA256 verifies that vtpmd correctly encrypts swtpm
// state and can recover it after a terminate+relaunch cycle, exercising the
// FetchVaultKey (NV-stored, no PCR binding) code path that is active when the
// host TPM has no SHA256 PCR bank.
func TestVtpmEncryptedStateNoSHA256() error {
	if _, err := os.Stat(vtpmdSockPath); err != nil {
		return fmt.Errorf("vtpmd socket not found at %s (is this running inside EVE?): %w",
			vtpmdSockPath, err)
	}

	if sha256BankAvailable() {
		return fmt.Errorf("SHA256 PCR bank is present on this TPM — test requires SHA256_BANK=N (run EVE with --no-sha256)")
	}
	fmt.Println("  [check] SHA256 PCR bank is absent — FetchVaultKey (NV-only) path will be exercised")

	uuid := newUUID()
	ctrlPath := fmt.Sprintf(swtpmCtrlFmt, uuid)
	pidPath := fmt.Sprintf(swtpmPidFmt, uuid)

	var testErr error
	defer func() {
		if err := vtpmdRequest("purge", uuid); err != nil {
			fmt.Printf("  warn: purge failed: %v\n", err)
		}
	}()

	// ── step 1: launch ────────────────────────────────────────────────────────
	fmt.Printf("  [1/4] launching swtpm instance %s\n", uuid)
	if testErr = vtpmdRequest("launch", uuid); testErr != nil {
		return fmt.Errorf("launch: %w", testErr)
	}

	if testErr = waitForPath(pidPath, 10*time.Second); testErr != nil {
		return fmt.Errorf("waiting for pid file: %w", testErr)
	}

	// ── step 2: verify encrypted marker ──────────────────────────────────────
	fmt.Printf("  [2/4] waiting for encrypted-state marker\n")
	if testErr = waitForEncryptedMarker(uuid, 10*time.Second); testErr != nil {
		return fmt.Errorf("encrypted marker: %w", testErr)
	}
	fmt.Printf("  [2/4] encrypted marker present (/persist/swtpm/%s.encrypted = Y)\n", uuid)
	dumpStateHeader(uuid)

	// Verify swtpm is responsive before terminate.
	if testErr = probeSwtpm(ctrlPath); testErr != nil {
		return fmt.Errorf("swtpm probe before terminate: %w", testErr)
	}

	// ── step 3: terminate then re-launch (key recovery) ───────────────────────
	fmt.Printf("  [3/4] terminating instance\n")
	if testErr = vtpmdRequest("terminate", uuid); testErr != nil {
		return fmt.Errorf("terminate: %w", testErr)
	}
	time.Sleep(500 * time.Millisecond)

	fmt.Printf("  [3/4] re-launching — vtpmd must recover the encryption key from TPM NV\n")
	if testErr = vtpmdRequest("launch", uuid); testErr != nil {
		return fmt.Errorf("re-launch after terminate: %w", testErr)
	}

	if testErr = waitForPath(pidPath, 10*time.Second); testErr != nil {
		return fmt.Errorf("waiting for pid file after re-launch: %w", testErr)
	}

	// ── step 4: verify swtpm is functional after re-launch ───────────────────
	fmt.Printf("  [4/4] verifying swtpm is responsive after re-launch with recovered key\n")
	if testErr = probeSwtpm(ctrlPath); testErr != nil {
		return fmt.Errorf("swtpm probe after re-launch: %w", testErr)
	}

	fmt.Printf("  [4/4] swtpm is responsive; encrypted state survived terminate+relaunch\n")
	return nil
}
