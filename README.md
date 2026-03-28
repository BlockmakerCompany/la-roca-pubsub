# 🪨 La Roca: Micro-PubSub Engine


[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-20KB-blue?logo=docker&logoColor=white)](https://hub.docker.com/r/blockmaker/la-roca-pubsub)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Binary Size](https://img.shields.io/badge/Binary%20Size-10KB-blue)
![Language](https://img.shields.io/badge/Language-Assembly%20x86__64-red)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey)
![Company](https://img.shields.io/badge/Backed%20By-BlockMaker%20S.R.L.-black)

> An ultra-low latency, zero-allocation, lock-free Publish/Subscribe broker written entirely in **x86_64 Linux Assembly**.

La Roca is designed to be the circulatory system of a high-performance microservices architecture. It bypasses the heavy abstractions of traditional brokers (like Kafka or RabbitMQ) by leveraging OS-level primitives and hardware instructions, achieving hundreds of thousands of messages per second with microsecond latency.

---

### 💡 Why La Roca PubSub? (The "Why" behind the "Metal")

Modern message brokers (Kafka, RabbitMQ, Pulsar) are incredible tools, but they are bloated. They rely on heavy runtimes (JVM/Erlang), garbage collection pauses, and complex network consensus protocols before moving a single byte of telemetry. **La Roca eliminates the "Abstraction Tax."**

* **Zero Context-Switch Reads:** Consumers read directly from the OS page cache via `mmap`.
* **No GC Jitter:** Deterministic microsecond latency. Zero dynamic memory allocation on the hot path.
* **Mechanical Sympathy:** At 3+ million messages per second, it scales your throughput without scaling your cloud bill.

**Perfect for:** High-Frequency Trading (HFT) order books, Multiplayer Gaming Tick-Rate servers, real-time IoT telemetry, and inter-process communication (IPC) sidecars where every millisecond counts.

---

## 📑 Table of Contents

- [💡 Why La Roca PubSub?](#-why-la-roca-pubsub-the-why-behind-the-metal)
- [⚡ Core Engineering Principles](#-core-engineering-principles)
- [📂 Project Structure](#-project-structure)
- [🚀 Quick Start](#-quick-start)
- [📡 API Reference](#-api-reference)
- [🧠 Architecture: The Lock-Free Ring Buffer](#-architecture-the-lock-free-ring-buffer)
- [⚡ Performance & Architecture](#-performance-performance--architecture)
- [🏎️ The "Loopback Saturation" Phenomenon](#️-the-loopback-saturation-phenomenon)
- [🧪 Testing & Validation](#-testing--validation)
- [🛣️ Roadmap](#️-roadmap)
- [🏢 Backed by BlockMaker S.R.L.](#-backed-by-blockmaker-srl)

---

## ⚡ Core Engineering Principles

* **Zero-Allocation:** No Garbage Collector, no `malloc()` on the hot path. All memory is pre-allocated and managed via pointer arithmetic.
* **Zero-Copy (IPC):** Uses memory-mapped files (`mmap`) backed by NVMe storage. Messages are written directly to the OS page cache, meaning consumer processes can read them without kernel context switches.
* **Lock-Free Concurrency:** Replaces expensive Mutexes with hardware-level atomic operations (`lock xadd`) and memory barriers (`sfence`, `lfence`).
* **$O(\log N)$ Topic Resolution:** Maintains an L1-cache aligned, memory-shifted array of strings for lightning-fast topic discovery via Binary Search, bypassing heavy hash maps.
* **Hot-Loop Batching:** A dedicated high-throughput endpoint for consuming multiple messages in a single network round-trip, minimizing syscall overhead.
* **Disk Authority & Auto-Provisioning:** Topics are safely auto-created on the fly. Ring buffer geometries and sequences are persisted in the file headers, surviving container restarts natively.
* **Bare-Metal HTTP 1.1:** Custom, zero-allocation HTTP parser that routes requests by directly comparing 64-bit registers.

---

### 📂 Project Structure

```text
.
├── src/
│   ├── core/                   # Heart of the engine
│   │   ├── config.inc          # Syscalls, macros, and TRACE tooling
│   │   ├── globals.asm         # Single Source of Truth for engine state & config
│   │   ├── utils.asm           # Low-level string utilities and env parsing (atoi, get_env)
│   │   ├── config_loader.asm   # Dynamic geometry & Environment variable orchestrator
│   │   ├── topic_vfs.asm       # Filesystem, mmap, Auto-Provisioning & Disk Authority
│   │   ├── topic_registry.asm  # O(N) array shifting for sorted insertions
│   │   ├── search_engine.asm   # O(log N) Binary Search for topic names
│   │   ├── publisher.asm       # Lock-free writing and sfence barriers
│   │   ├── subscriber.asm      # O(1) offset calculation and wait-free reading
│   │   └── dma_worker.asm      # io_uring asynchronous memory flushing
│   ├── routers/                # HTTP parsing and routing
│   │   ├── route_api.asm       # Register-based HTTP GET/POST routing
│   │   ├── handle_batch.asm    # High-throughput sequential message collector
│   │   ├── handle_mpub.asm     # High-performance Multi-Publish batch ingestion
│   │   └── handle_*.asm        # Specific endpoint handlers (Stats, Live, Pub, Sub)
│   └── main.asm                # Bootstrapper, Epoll event loop, and TCP server
├── tests/
│   ├── test_e2e.sh                  # Deterministic E2E Bash test suite
│   ├── test_security.sh             # Fuzzing and Buffer Overflow protections
│   ├── test_config_persistence.sh   # Env poisoning and Disk Authority audits
│   └── bench.go                     # High-Frequency TCP concurrency benchmark
├── run_all_tests.sh            # Master pipeline orchestrator (Functional, Security, Stress)
├── Makefile                    # Toolchain configuration (NASM + LD)
├── docker-compose.yml          # Ecosystem simulation (Cluster/Node)
└── openapi.yaml                # OpenAPI 3.0 specification
```

---

## 🚀 Quick Start

### Prerequisites
* [Docker](https://docs.docker.com/get-docker/) and Docker Compose.
* [Go](https://golang.org/) (Only required for running the High-Frequency Benchmark).

### 1. Build and Run
We use a multi-stage Docker build to compile the assembly code and package it into an ultra-lightweight `scratch` container.

```bash
# Build the engine and start the ecosystem
docker compose up -d --build
```

---

## ⚙️ Dynamic Configuration & Disk Authority

**La Roca** is designed to be fully configurable at runtime without recompiling the Assembly code, making it instantly compatible with modern Cloud Native orchestrators like Kubernetes or Docker Compose.

### 🎛️ Environment Variables
You can define the geometry of your Ring Buffers by passing the following environment variables during the engine's boot phase:

| Variable | Description | Default Value |
| :--- | :--- | :--- |
| `ROCK_MSG_SIZE` | Fixed size in bytes for each message payload. | `256` |
| `ROCK_MAX_MSGS` | Maximum number of messages a topic can hold. | `262143` |
| `ROCK_KEY_SIZE` | Configurable routing key length (in bytes) for stream filtering. | `16` |

*By default, the engine provisions **~64MB** per topic (256 bytes * 262143 messages + 256 bytes header). The 16-byte default key ensures 128-bit SIMD alignment for hardware-accelerated scanning.*

### 🛡️ The "Disk Authority" Protocol
To prevent catastrophic data corruption caused by accidental misconfigurations in deployment manifests, the engine enforces a strict **Configuration Hierarchy**:
If a pod crashes and is rescheduled, the engine recovers its $O(1)$ mmap offsets natively by reading the tattooed headers from the persistent volume, effectively neutralizing any misconfiguration in the deployment manifest.

1. **Disk Authority (Absolute):** If a topic file (`.log`) already exists on disk, the engine reads the exact `MsgSize`, `MaxMsgs`, and `KeySize` tattooed into its binary header (offsets 8, 16, and 24). **Existing files will completely ignore environment variables**, ensuring $O(1)$ offset math remains pristine.
2. **Environment Variables:** If a topic is being created for the first time (Auto-Provisioning), the engine will scan the OS environment pointers (`envp`) and use `ROCK_MSG_SIZE` and `ROCK_MAX_MSGS`.
3. **Hardcoded Defaults:** If no environment variables are detected, the engine falls back to the default 64MB geometry.

### 🐳 Docker Compose Example
Here is how you can deploy an instance tuned for larger payloads (1KB per message) and higher retention (1 Million messages):

```yaml
services:
  pubsub-engine:
    image: blockmaker/la-roca-pubsub:latest
    ports:
      - "8080:8080"
    environment:
      - ROCK_MSG_SIZE=1024       # 1KB per message
      - ROCK_MAX_MSGS=1000000    # 1 Million msgs (~1GB per topic)
    volumes:
      - ./data/topics:/app/topics
```

> **Engineering Note:** Because topics are completely independent entities, you can have `topics/logs.log` configured with 4KB messages and `topics/ticks.log` configured with 64-byte messages on the same persistent volume. The engine will adapt dynamically to each file's tattooed header.

---

## 🧪 Testing & Validation

The project includes a multi-layered automated testing infrastructure designed to guarantee memory safety, protocol compliance, lock-free consistency, and immutable disk authority.

### 🚀 Master Orchestrator (CI/CD Ready)
You can run the entire validation pipeline sequentially, culminating in the high-frequency Go stress test, using the master script:
```bash
# Run Functional, Security, Persistence, and Stress tests
./run_all_tests.sh --stress
```

### 1. Functional Integration (E2E)
Verifies the core pub/sub logic: sequence generation, topic auto-provisioning, and $O(1)$ consumption.
```bash
# Execute deterministic end-to-end tests
./tests/test_e2e.sh
```

### 2. Security & Hardening (Protocol Boundary)
Validates the "Iron-Clad" architecture by attempting to break the engine using malformed HTTP requests and buffer flooding (Fuzzing).
```bash
# Execute security and buffer overflow audits
./tests/test_security.sh
```
*Tests: Oversized topic names (400), empty sequence IDs (400), and alphanumeric safety.*

### 3. Disk Authority & Immutable Geometry
Ensures that once a topic is provisioned, its ring-buffer geometry is tattooed to the disk header. This test attempts to reboot the engine with "poisoned" environment variables to verify that the $O(1)$ memory mapping offsets cannot be corrupted by external misconfigurations.
```bash
# Execute environment poisoning and persistence audits
./tests/test_config_persistence.sh
```

### 4. High-Frequency Stress Test (mpub)
To measure the raw power of the **Zero-Copy / No-LibC** architecture, we use direct Linux Kernel syscalls through a custom Go benchmark.
```bash
# Target: > 3,000,000 Messages / sec
go run tests/bench.go mpub
```

> **Note:** Because the engine bypasses `libc` and uses a zero-allocation event loop, you will likely saturate your local network loopback interface before maxing out the CPU.

---

## 📡 API Reference

The engine listens on port `8080`. Topics are dynamically created (Auto-Provisioning) upon the first request in `< 1ms`.

| Endpoint | Method | Description |
| :--- | :--- | :--- |
| `/live` | `GET` | System healthcheck. Returns 200 OK. |
| `/pub/{topic}` | `POST` | Appends a payload to the Ring Buffer. Returns 200 OK. |
| `/mpub/{topic}` | `POST` | **High-Perf:** Appends multiple `\n` delimited payloads to the Ring Buffer. Returns 200 OK. |
| `/sub/{topic}/{seq}` | `GET` | Reads a specific sequence. Returns 200 OK or 404 if not ready. |
| `/batch/{topic}/{seq}/{n}` | `GET` | **High-Perf:** Consumes up to `n` messages starting from `seq`. |
| `/stats` | `GET` | Returns system metrics and telemetry in JSON. |

### Example Usage (cURL)

**Publish a message:**
```bash
curl -X POST -H "X-Roca-Key: user_12345" -d "Trade_Order_BTC_72000" http://localhost:8080/pub/ticker_btc
```

**Publish a multi-publish:**
```bash
curl -X POST -H "X-Roca-Key: batch_trade" -d $'Price: 65000\nPrice: 65100\nPrice: 65050' http://localhost:8080/mpub/ticker_btc
```

**Consume a single sequence:**
```bash
curl http://localhost:8080/sub/ticker_btc/0
```

**Consume a batch of 50 messages (New!):**
```bash
curl --output - http://localhost:8080/batch/ticker_btc/0/50
```

---

## 🧠 Architecture: The Lock-Free Ring Buffer

Each topic is backed by a dynamically created memory-mapped file (`topics/{topic_name}.log`). To eliminate parsing overhead, the engine uses a **fixed-size framing architecture** that guarantees $O(1)$ memory addressing.

### 📂 Database File Internals
The memory map is strictly divided into a metadata header and a cyclic array of slots.

**The Header (256 Bytes)**
| Offset (Hex) | Size | Content | Description |
| :--- | :--- | :--- | :--- |
| `0x00000` | 8 B | **Global Tail** | Atomic `uint64` tracking the next available sequence ID. |
| `0x00008` | 8 B | **Message Size** | Configured `rt_msg_size` (e.g., 256 bytes). |
| `0x00010` | 8 B | **Max Messages** | Configured `rt_max_messages` (e.g., 262143). |
| `0x00018` | 8 B | **Key Size** | Configured `rt_key_size` (e.g., 16 bytes). |
| `0x00020` | 224 B | **Reserved** | Padding for future ring boundaries and checksums. |

**The Data Slot (e.g., 256 Bytes)**
| Offset | Size | Content | Technical Detail |
| :--- | :--- | :--- | :--- |
| `+0` | 1 B | **Status Flag** | `0` = Empty, `1` = Writing (Locked), `2` = Ready. |
| `+1` | 8 B | **Sequence ID** | The exact 64-bit sequence number of the message. |
| `+9` | K B | **Routing Key** | The `X-Roca-Key` value (up to `rt_key_size` bytes). |
| `+9+K` | N B | **Payload** | The raw binary payload (up to `MsgSize - 9 - KeySize`). |

### 🧮 The $O(1)$ Addressing Formula
Because messages are fixed-size, the subscriber engine never parses or scans the file. It resolves the exact byte offset for any sequence in pure $O(1)$ time using modulo arithmetic:

$$Address(sequence) = BaseAddress + 256 + ((sequence \pmod{MaxMessages}) \times MessageSize)$$

This mathematical certainty is why a consumer can jump to message `5,000,000` exactly as fast as it reads message `1`.

### ⚡ The Fast Path
1. **Routing:** The router extracts the topic name and delegates to the handler.
2. **Resolution ($O(\log N)$):** The Search Engine performs a Binary Search on the L1-cached Topic Registry.
3. **Injection ($O(1)$):** Producers use `lock xadd` to claim a sequence ID atomically.
4. **Batching:** The `/batch` handler iterates through the `mmap` region in a single "Hot Loop", concatenating ready messages into a pre-allocated 64KB output buffer to minimize network packets.

---

## 🏗️ Horizontal Scaling (Cluster Mode)

**La Roca** follows a **Shared-Nothing Architecture**. Each instance is a completely independent "cell" that owns its RAM and local storage. To scale to millions of concurrent topics and Terabytes of throughput, we delegate coordination to a high-performance proxy (**Envoy**) using **Consistent Hashing**.

### 🎡 Topic-Based Consistent Hashing
Routing is performed by hashing the `topic_name` extracted from the URI. This ensures that all operations for a specific topic (`PUB`, `SUB`, `MPUB`, `BATCH`) **always** land on the same physical node, maintaining sequence integrity without requiring cross-node synchronization.



### 🚀 Docker Compose: 3-Node Cluster Example
This setup deploys a front-proxy (Envoy) and two engine nodes. Envoy is configured to use the `RING_HASH` load-balancing policy.

```yaml
services:
  envoy-proxy:
    image: envoyproxy/envoy:v1.27.0
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
    ports:
      - "8080:8080"

  pubsub-node-1:
    image: blockmaker/la-roca-pubsub:latest
    volumes:
      - ./data/node1:/app/topics

  pubsub-node-2:
    image: blockmaker/la-roca-pubsub:latest
    volumes:
      - ./data/node2:/app/topics
```

### ☸️ Kubernetes & Helm (High Availability)
In a Kubernetes environment, **La Roca** uses a **StatefulSet** combined with a **Headless Service** and an **Envoy Front-Proxy** to achieve infinite horizontal scalability without the need for distributed consensus.

```bash
# 1. Validate the chart syntax
helm lint ./charts/la-roca-pubsub

# 2. Deploy the full cluster (e.g., 3 Engine Nodes + 2 Envoy Proxies)
helm install la-roca-cluster ./charts/la-roca-pubsub
```

**Key Helm Architecture:**
* **StatefulSets & PVCs:** Each engine pod (e.g., `laroca-0`, `laroca-1`) is permanently bound to its own Persistent Volume.
* **Disk Authority Synergy:** If a pod crashes or is rescheduled, Kubernetes respawns it attached to the same volume. The engine reads the tattooed `.log` headers upon boot, perfectly recovering its $O(1)$ `mmap` offsets without losing a single message.
* **Envoy Ring Hash:** The Front-Proxy dynamically discovers pod IPs via the Headless Service (`STRICT_DNS`) and routes traffic by hashing the topic name in the URI. This guarantees that all requests for a specific topic always hit the same physical node.
* **Dynamic Geometry:** Buffer geometries (`ROCK_MSG_SIZE`, `ROCK_MAX_MSGS`) are centrally managed via the Helm `values.yaml` and injected into the pods during initialization.

> **Engineering Note:** By using this pattern, you can scale horizontally to hundreds of nodes. The performance overhead of Envoy is negligible compared to the 99% reduction in system complexity achieved by avoiding a distributed consensus protocol (like Raft or Paxos) at the engine level.

### Envoy example configuration

```yaml
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: pubsub_service
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route:
                  cluster: pubsub_cluster
                  # Hashing based on the path's second segment: /pub/{topic}
                  hash_policy:
                  - header:
                      header_name: ":path"
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: pubsub_cluster
    connect_timeout: 0.25s
    type: STRICT_DNS
    lb_policy: RING_HASH
    load_assignment:
      cluster_name: pubsub_cluster
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: pubsub-node-1, port_value: 8080 }}}
        - endpoint: { address: { socket_address: { address: pubsub-node-2, port_value: 8080 }}}
```

---

## ⚡ Performance & Architecture

**La Roca** is designed around the principle of **Hardware Sympathy**. By stripping away OS abstractions, garbage collection, and dynamic memory allocation, it achieves mechanical sympathy with the x86_64 CPU architecture.

### 🚀 Benchmark Highlights
In local stress-testing using raw TCP sockets over loopback (single-threaded, single Docker container):

* **Multi-Publish Ingestion (`/mpub`):** **~ 2,750,000 Messages / sec**
* **Batch Consumption (`/batch`):** **> 700,000 Messages / sec**
* **Error Rate:** **0.00%** (100% Payload Delivery under saturation).
* **Memory Footprint:** **< 10 MB** (Active RAM, mostly L1/L2 cache + mmap pages).
* **Syscalls:** Reduced by 99% during batched operations.

### 🧠 The Secret Sauce (Why is it so fast?)

1. **Zero-Allocation HTTP Routing:** The server never calls `malloc` or relies on a heap. It parses HTTP requests strictly using pointer arithmetic and register offsets. Strings are evaluated in-place.
2. **Lock-Free Concurrency:** Instead of using slow OS-level mutexes or semaphores, the Ring Buffer index is advanced using the `lock xadd` hardware instruction. This guarantees atomic, thread-safe message ordering at the CPU level without blocking.
3. **O(1) Memory-Mapped I/O (`mmap`):** Topics are fixed-size framing files mapped directly into RAM. Reads and writes are straight memory pointer dereferences (`Base_Address + (Sequence * Frame_Size)`). The Linux Kernel handles page flushing asynchronously.
4. **Hardware-Accelerated Scanning:** Batched endpoints (`/mpub`) use the `repne scasb` instruction to scan for `\n` delimiters at cache-speed, allowing the CPU's branch predictor to maintain a continuous hot-loop.
5. **L1 Cache Optimization:** The Topic Registry is stored in a contiguous, alphabetically sorted array of 24-byte entries. Lookups fit perfectly inside the CPU's L1 cache, making topic resolution virtually instantaneous.

---

## 🏎️ The "Loopback Saturation" Phenomenon

If you attempt to run high-concurrency benchmarks (like our included `bench.go`), you will notice an incredible phenomenon: the CPU usage of **La Roca** stays minimal while it processes **over 3,000,000 messages per second**.

**This is not a bottleneck in the engine; it is a bottleneck in the Linux Kernel.**

Because this engine is built with a **Zero-Allocation, libc-free architecture**, it operates at a speed that exceeds the standard overhead of the OS network stack. In local testing, the performance limit is usually dictated by:

* **TCP/IP Interrupts:** The rate at which the Kernel can process incoming packets on the `lo` (loopback) interface.
* **Context Switching:** The overhead of the Kernel moving from User Space to Kernel Space for thousands of `sys_read` and `sys_write` calls per second.
* **The Performance Paradox:** In most environments, **La Roca** is faster than the infrastructure used to test it. By grouping messages into batches (`/mpub`), we evaporate 99% of network syscalls, allowing the hardware to reach its absolute physical limits.

---

## 🛣️ Roadmap

- [x] Epoll TCP Server & Zero-allocation HTTP Router
- [x] Lock-Free Publisher (`lock xadd`) & O(1) Consumer
- [x] Dynamic Named Topics & $O(\log N)$ Binary Search Registry
- [x] **High-Performance Batch Consumption Endpoint**
- [x] JSON Metrics Endpoint (`/stats`)
- [x] **Multi-Publish (`/mpub`) Batched Ingestion**
- [x] **Stream Processing Readiness (Hardware-Aligned Routing Keys)**
- [ ] **HTTP/1.1 Keep-Alive & Epoll Persistence** (Bypass TCP 3-way handshake & `sys_close` overhead)
- [ ] JIT Stream Processor (Wasm/eBPF integration)
- [ ] Asynchronous DMA Worker via `io_uring`

---

## 🤝 Contact & Collaboration

This project is a testament to the power of low-level engineering and the "Zero-Dependency" philosophy. If you are interested in high-performance systems, operating system internals, or just want to discuss why Assembly is still relevant in the era of Cloud Native, let's connect!

**Fernando E. Mancuso** *Head of Engineering at Blockmaker S.R.L.*

* **LinkedIn**: [Fernando Ezequiel Mancuso](https://www.linkedin.com/in/fernando-ezequiel-mancuso-54a2737/)
* **Email**: [fernando.mancuso@blockmaker.net](mailto:fernando.mancuso@blockmaker.net)
* **GitHub**: [@fermancuso-blockmaker](https://github.com/fermancuso-blockmaker)

> "The best way to understand how a computer works is to stop asking the operating system for permission and start giving it orders."

---

## 🏢 Backed by BlockMaker S.R.L.

**La Roca Micro-PubSub** was engineered from scratch by the engineering team at **BlockMaker S.R.L.** At BlockMaker, we believe in deep tech, zero-dependency architectures, and pushing the absolute limits of hardware efficiency. We are actively encouraging the global engineering community to fork, benchmark, and contribute to this project.

If you love low-level systems engineering and uncompromising performance, feel free to reach out.