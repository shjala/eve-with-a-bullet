// Copyright (c) 2026 Zededa, Inc.
// SPDX-License-Identifier: Apache-2.0

// Test runner for EVE integration tests.
// Usage:
//
//	tests --list                  list all available tests
//	tests --test <name>           run a single test by name
//	tests --all                   run all tests
package main

import (
	"flag"
	"fmt"
	"os"
)

// testCase describes a single integration test.
type testCase struct {
	name string
	desc string
	run  func() error
}

var registry []testCase

// register adds a test to the global registry. Called from init() in each test file.
func register(name, desc string, fn func() error) {
	registry = append(registry, testCase{name: name, desc: desc, run: fn})
}

func main() {
	testName := flag.String("test", "", "Name of the test to run")
	runAll := flag.Bool("all", false, "Run all registered tests")
	listTests := flag.Bool("list", false, "List all available tests")
	flag.Parse()

	if *listTests {
		fmt.Println("Available tests:")
		for _, t := range registry {
			fmt.Printf("  %-35s %s\n", t.name, t.desc)
		}
		return
	}

	if !*runAll && *testName == "" {
		fmt.Fprintln(os.Stderr, "Usage: tests --test <name> | --all | --list")
		os.Exit(1)
	}

	var toRun []testCase
	if *runAll {
		toRun = registry
	} else {
		for _, t := range registry {
			if t.name == *testName {
				toRun = append(toRun, t)
				break
			}
		}
		if len(toRun) == 0 {
			fmt.Fprintf(os.Stderr, "Test %q not found. Run --list to see available tests.\n", *testName)
			os.Exit(1)
		}
	}

	failed := 0
	for _, t := range toRun {
		fmt.Printf("[RUN ] %s\n", t.name)
		if err := t.run(); err != nil {
			fmt.Printf("[FAIL] %s: %v\n", t.name, err)
			failed++
		} else {
			fmt.Printf("[PASS] %s\n", t.name)
		}
	}

	if failed > 0 {
		fmt.Fprintf(os.Stderr, "\n%d/%d tests failed\n", failed, len(toRun))
		os.Exit(1)
	}
	fmt.Printf("\nAll %d test(s) passed\n", len(toRun))
}
