// ============================================================================
// Module: tests/bench.go
// Project: La Roca Micro-PubSub
// Responsibility: High-frequency stress tester using raw TCP sockets and
//                 Goroutines to bypass client-side HTTP allocation overhead.
//                 Provides metrics for pub, sub, batch, and mpub throughput.
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
	reqPublish = []byte("POST /pub/bench_topic HTTP/1.1\r\nHost: localhost\r\nContent-Length: 21\r\n\r\nTrade_Order_BTC_72000")
	reqConsume = []byte("GET /sub/bench_topic/0 HTTP/1.1\r\nHost: localhost\r\n\r\n")
	reqBatch   = []byte(fmt.Sprintf("GET /batch/bench_topic/0/%d HTTP/1.1\r\nHost: localhost\r\n\r\n", batchSize))
	reqMPub    []byte // Dynamically generated in init()
)

var (
	opsCount uint64 // Atomic counter for successful requests
	errCount uint64 // Atomic counter for failed requests
)

func init() {
	// -------------------------------------------------------------------------
	// Pre-assemble the bulk payload for /mpub ingestion.
	// We do this here to ensure Go's string allocation doesn't pollute the
	// benchmark metrics.
	// -------------------------------------------------------------------------
	var bodyBuilder strings.Builder
	for i := 0; i < batchSize; i++ {
		// Use a payload size similar to the standard /pub example
		bodyBuilder.WriteString(fmt.Sprintf("Trade_Order_BTC_%05d", i))
		if i < batchSize-1 {
			bodyBuilder.WriteString("\n")
		}
	}
	body := bodyBuilder.String()

	// Construct the final raw HTTP request buffer
	reqMPub = []byte(fmt.Sprintf(
		"POST /mpub/bench_topic HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n%s",
		len(body), body,
	))
}

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	mode := os.Args[1]
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
	default:
		printUsage()
		os.Exit(1)
	}

	fmt.Printf("🚀 Starting High-Frequency Benchmark (%s)\n", mode)
	fmt.Printf("Target: %s | Concurrency: %d | Duration: %ds\n", targetAddr, concurrency, duration)
	if mode == "batch" || mode == "mpub" {
		fmt.Printf("Batch Size: %d messages per request\n", batchSize)
	}
	fmt.Println("---------------------------------------------------------")

	// Spawn worker goroutines (The Hammer)
	for i := 0; i < concurrency; i++ {
		go hammer(payload)
	}

	// Run for the specified duration
	time.Sleep(time.Duration(duration) * time.Second)

	finalOps := atomic.LoadUint64(&opsCount)
	finalErr := atomic.LoadUint64(&errCount)
	rps := finalOps / uint64(duration)

	fmt.Printf("✅ Benchmark Completed!\n")
	fmt.Printf("Total Requests: %d\n", finalOps)
	fmt.Printf("Total Errors:   %d\n", finalErr)
	fmt.Printf("Throughput:     %d Requests/sec\n", rps)

	if mode == "batch" || mode == "mpub" {
		fmt.Printf("Real Throughput: ~%d Messages/sec\n", rps*uint64(batchSize))
	}
	fmt.Println("---------------------------------------------------------")
	os.Exit(0)
}

func printUsage() {
	fmt.Println("Usage: go run tests/bench.go [pub|sub|batch|mpub]")
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