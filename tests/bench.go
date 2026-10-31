// ============================================================================
// Module: tests/bench.go
// Project: La Roca Micro-PubSub
// Responsibility: High-frequency stress tester using raw TCP sockets and
//                 Goroutines to bypass client-side HTTP allocation overhead.
//                 Provides metrics for pub, sub, batch, and mpub throughput.
//                 Updated for v1.3.0 (Stream Processing & Routing Keys).
//                 Fails the pipeline (exit 1) on any error, and can run a
//                 post-stress healthcheck via --verify.
// ============================================================================

package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

const (
	targetAddr  = "localhost:8080"
	concurrency = 100 // Number of simultaneous TCP connections
	duration    = 10  // Benchmark duration in seconds
	batchSize   = 100 // Number of messages per request in batch/mpub modes
)

// Pre-baked HTTP wire-format payloads to minimize per-request overhead
var (
	reqPublish []byte
	reqConsume []byte
	reqBatch   []byte
	reqMPub    []byte
)

var (
	opsCount uint64 // Atomic counter for successful requests
	errCount uint64 // Atomic counter for failed requests
)

func init() {
	// -------------------------------------------------------------------------
	// Pre-assemble the payloads. We do this in init() so string allocations
	// do not pollute the benchmark's CPU or memory metrics.
	// We inject "X-Roca-Key" to stress the new hardware-aligned key extraction.
	// -------------------------------------------------------------------------

	// 1. Single Publish Payload
	bodyPub := "Trade_Order_BTC_72000"
	reqPublish = []byte(fmt.Sprintf(
		"POST /pub/bench_topic HTTP/1.1\r\nHost: localhost\r\nX-Roca-Key: bench_key_01\r\nContent-Length: %d\r\n\r\n%s",
		len(bodyPub), bodyPub,
	))

	// 2. Single Consume Payload
	reqConsume = []byte("GET /sub/bench_topic/0 HTTP/1.1\r\nHost: localhost\r\n\r\n")

	// 3. Batch Consume Payload
	reqBatch = []byte(fmt.Sprintf("GET /batch/bench_topic/0/%d HTTP/1.1\r\nHost: localhost\r\n\r\n", batchSize))

	// 4. Multi-Publish (MPUB) Payload
	var bodyBuilder strings.Builder
	for i := 0; i < batchSize; i++ {
		bodyBuilder.WriteString(fmt.Sprintf("Trade_Order_BTC_%05d", i))
		if i < batchSize-1 {
			bodyBuilder.WriteString("\n")
		}
	}
	bodyMPub := bodyBuilder.String()

	reqMPub = []byte(fmt.Sprintf(
		"POST /mpub/bench_topic HTTP/1.1\r\nHost: localhost\r\nX-Roca-Key: bench_batch_k\r\nContent-Length: %d\r\n\r\n%s",
		len(bodyMPub), bodyMPub,
	))
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	// Parse arguments: the mode, plus optional --verify and -duration=SECONDS.
	mode := ""
	verify := false
	dur := duration
	for _, arg := range os.Args[1:] {
		switch {
		case arg == "--verify":
			verify = true
		case strings.HasPrefix(arg, "-duration="):
			fmt.Sscanf(arg, "-duration=%d", &dur)
		case arg == "pub" || arg == "sub" || arg == "batch" || arg == "mpub":
			mode = arg
		default:
			printUsage()
			os.Exit(1)
		}
	}
	if mode == "" {
		printUsage()
		os.Exit(1)
	}

	var payload []byte

	switch mode {
	case "pub":
		payload = reqPublish
	case "sub":
		payload = reqConsume
	case "batch":
		payload = reqBatch
	case "mpub":
		payload = reqMPub
	}

	fmt.Printf("🚀 Starting High-Frequency Benchmark (%s)\n", mode)
	fmt.Printf("Target: %s | Concurrency: %d | Duration: %ds\n", targetAddr, concurrency, dur)
	if mode == "batch" || mode == "mpub" {
		fmt.Printf("Batch Size: %d messages per request\n", batchSize)
	}
	fmt.Println("---------------------------------------------------------")

	// Spawn worker goroutines (The Hammer)
	for i := 0; i < concurrency; i++ {
		go hammer(payload)
	}

	// Run for the specified duration
	time.Sleep(time.Duration(dur) * time.Second)

	finalOps := atomic.LoadUint64(&opsCount)
	finalErr := atomic.LoadUint64(&errCount)
	rps := finalOps / uint64(dur)

	fmt.Printf("✅ Benchmark Completed!\n")
	fmt.Printf("Total Requests: %d\n", finalOps)
	fmt.Printf("Total Errors:   %d\n", finalErr)
	fmt.Printf("Throughput:     %d Requests/sec\n", rps)

	if mode == "batch" || mode == "mpub" {
		fmt.Printf("Real Throughput: ~%d Messages/sec\n", rps*uint64(batchSize))
	}
	fmt.Println("---------------------------------------------------------")

	exitCode := 0

	if finalErr > 0 {
		fmt.Printf("❌ FAILED: %d errors detected during benchmark\n", finalErr)
		exitCode = 1
	}

	// Post-stress stability probe: the engine must still serve /live and /stats
	// after being hammered. This is what catches register-corruption hangs that
	// leave the event loop alive but unresponsive.
	if verify {
		fmt.Println("🔍 Running post-stress healthcheck (--verify)...")
		if !healthcheck() {
			fmt.Printf("❌ FAILED: healthcheck after stress did not return 200\n")
			exitCode = 1
		}
	}

	os.Exit(exitCode)
}

func printUsage() {
	fmt.Println("Usage: go run tests/bench.go [pub|sub|batch|mpub] [--verify] [-duration=SECONDS]")
	fmt.Println("  --verify          After the hammer, probe /live and /stats; fail if not 200")
	fmt.Println("  -duration=SECONDS Benchmark duration (default 10)")
}

// healthcheck probes /live and /stats and returns true only if both answer 200.
func healthcheck() bool {
	ok := true
	for _, path := range []string{"/live", "/stats"} {
		conn, err := net.Dial("tcp", targetAddr)
		if err != nil {
			fmt.Printf("❌ healthcheck %s: dial failed: %v\n", path, err)
			return false
		}
		req := []byte("GET " + path + " HTTP/1.1\r\nHost: localhost\r\n\r\n")
		if _, err := conn.Write(req); err != nil {
			fmt.Printf("❌ healthcheck %s: write failed: %v\n", path, err)
			conn.Close()
			return false
		}
		buf := make([]byte, 4096)
		n, err := conn.Read(buf)
		conn.Close()
		if err != nil || n == 0 {
			fmt.Printf("❌ healthcheck %s: read failed (err=%v, n=%d)\n", path, err, n)
			ok = false
			continue
		}
		if !strings.Contains(string(buf[:n]), "200") {
			fmt.Printf("❌ healthcheck %s: expected HTTP 200, got:\n%s\n", path, string(buf[:n]))
			ok = false
			continue
		}
		fmt.Printf("✅ healthcheck %s OK (200)\n", path)
	}
	return ok
}

func hammer(payload []byte) {
	// Shared buffer to accommodate large L7 responses (64KB)
	readBuf := make([]byte, 65536)

	for {
		// We use short-lived TCP connections to stress the engine's accept/epoll cycle
		conn, err := net.Dial("tcp", targetAddr)
		if err != nil {
			atomic.AddUint64(&errCount, 1)
			time.Sleep(1 * time.Millisecond) // Backoff to prevent CPU saturation on connectivity drops
			continue
		}

		// Send pre-baked request
		_, err = conn.Write(payload)
		if err != nil {
			atomic.AddUint64(&errCount, 1)
			conn.Close()
			continue
		}

		// Drain response
		_, err = conn.Read(readBuf)
		if err != nil {
			atomic.AddUint64(&errCount, 1)
		} else {
			atomic.AddUint64(&opsCount, 1)
		}

		conn.Close()
	}
}
