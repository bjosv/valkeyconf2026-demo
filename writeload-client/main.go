// Command writeload is the demo's write-load generator. It holds a persistent,
// cluster-aware connection (valkey-go) so that slot migration during scaling and
// primary failover are handled by the client library (MOVED/ASK redirects and
// topology refresh), rather than being counted as lost writes.
//
// It prints a single, continuously-updated line:
//
//	Writes: <n>  Acked: <n>  LOST: <n>
//
// LOST is writes that still failed after the client's own reconnect/retry, i.e.
// genuine loss, not a transient failover blip.
//
// Configuration (environment):
//
//	VK_HOST      service/host to dial            (required)
//	VK_PORT      port                            (default 6379)
//	VK_USER      ACL username                    (default "demo")
//	VK_PASS      ACL password                    (default empty)
//	VK_TLS       "1" to enable TLS               (default "1")
//	VK_CACERT    CA cert path for TLS            (default "/tls/ca.crt")
//	VK_RPS       writes per second               (default 20)
//	VK_KEYS      distinct keys to cycle          (default 1000)
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/valkey-io/valkey-go"
)

// transient reports whether a write error is a temporary cluster-topology state
// that clears once the client refreshes: no node currently owns the slot
// (ErrNoSlot), the cluster is briefly down, or the server asks to try again.
// These occur during failover/rebalance and the write (unacknowledged) is safe
// to retry. Other errors (e.g. NOPERM, auth) are permanent and returned as-is.
func transient(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, valkey.ErrNoSlot) {
		return true
	}
	if verr, ok := valkey.IsValkeyErr(err); ok {
		if verr.IsClusterDown() || verr.IsTryAgain() {
			return true
		}
		if _, ok := verr.IsMoved(); ok {
			return true
		}
		if _, ok := verr.IsAsk(); ok {
			return true
		}
		// A server error that isn't one of the above (e.g. NOPERM, WRONGPASS)
		// is permanent; retrying won't help and would mask the real problem.
		return false
	}
	// Non-server errors are network/timeout level (connection reset or a dial
	// timeout to a just-deleted primary). valkey-go refreshes topology on these,
	// so a prompt retry finds the new primary.
	return true
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def, min int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		log.Fatalf("invalid %s %q: %v", key, v, err)
	}
	if n < min {
		log.Fatalf("%s=%d must be >= %d", key, n, min)
	}
	return n
}

// tlsConfig builds a TLS config that trusts the demo CA. Hostname verification
// is skipped to match the rest of the demo (self-signed certs whose SANs cover
// the in-cluster FQDNs but not every dial path).
func tlsConfig(caPath string) *tls.Config {
	pem, err := os.ReadFile(caPath)
	if err != nil {
		log.Fatalf("read CA %q: %v", caPath, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		log.Fatalf("no certificates parsed from CA %q", caPath)
	}
	return &tls.Config{RootCAs: pool, InsecureSkipVerify: true}
}

func main() {
	host := os.Getenv("VK_HOST")
	if host == "" {
		log.Fatal("VK_HOST not set")
	}
	port := env("VK_PORT", "6379")
	addr := host + ":" + port

	rps := envInt("VK_RPS", 20, 1)
	numKeys := envInt("VK_KEYS", 1000, 1)

	opt := valkey.ClientOption{
		InitAddress: []string{addr},
		Username:    env("VK_USER", "demo"),
		Password:    os.Getenv("VK_PASS"),
	}
	if env("VK_TLS", "1") == "1" {
		opt.TLSConfig = tlsConfig(env("VK_CACERT", "/tls/ca.crt"))
	}

	// The persistent client discovers the cluster topology and maintains
	// connections to every shard; it reroutes on MOVED/ASK and refreshes on
	// failover, so a promoted replica is picked up without a cold reconnect.
	client, err := valkey.NewClient(opt)
	if err != nil {
		log.Fatalf("connect failed: %v", err)
	}
	defer client.Close()

	ctx := context.Background()
	var writes, acked, lost int64

	fmt.Printf("write-load against %s as user %q\r\n\r\n", addr, opt.Username)

	// Retry a failed write before counting it as lost. During a rolling upgrade
	// or failover a slot's primary is unavailable while a replica is promoted,
	// and the whole cluster can report CLUSTERDOWN until every slot is covered
	// again. The write is unacknowledged, so re-sending it is safe (SET is
	// idempotent). Budget must outlast the promotion window; the default is
	// 100 x 200ms = 20s, well beyond a typical kind failover. Only a write that
	// still fails after all attempts is a genuine loss.
	retries := envInt("VK_RETRIES", 100, 1)
	retrySleep := time.Duration(envInt("VK_RETRY_MS", 200, 1)) * time.Millisecond

	interval := time.Second / time.Duration(rps)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Per-attempt timeout: long enough to let valkey-go complete an internal
	// redirect/topology refresh during scale migration (cutting it too short
	// turns a would-be-successful redirect into a failure), but bounded so a
	// hung dial to a just-deleted primary during failover fails and retries.
	attemptTimeout := time.Duration(envInt("VK_ATTEMPT_MS", 3000, 100)) * time.Millisecond

	keyIdx := 0
	var lastErr string
	for range ticker.C {
		key := fmt.Sprintf("demo:key:%d", keyIdx%numKeys)
		keyIdx++
		writes++
		wrote := false
		for attempt := 0; attempt < retries; attempt++ {
			attemptCtx, cancel := context.WithTimeout(ctx, attemptTimeout)
			err := client.Do(attemptCtx, client.B().Set().Key(key).Value(strconv.Itoa(keyIdx)).Build()).Error()
			cancel()
			if err == nil {
				wrote = true
				break
			}
			lastErr = err.Error()
			// Permanent errors (auth, ACL) won't be fixed by waiting; stop and
			// count as lost so the cause is visible rather than masked by retries.
			if !transient(err) {
				break
			}
			time.Sleep(retrySleep)
		}
		if wrote {
			acked++
		} else {
			lost++
		}
		// Overwrite one line with \r. Fixed-width fields keep the line length
		// constant, so no clear-to-EOL is needed. Kept comfortably under the
		// write-load pane width so it never wraps (a wrapped line makes \r return
		// to the wrong row and looks like new lines). Rendered via a TTY.
		fmt.Printf("\rWrites: %-7d Acked: %-7d LOST: %-5d", writes, acked, lost)
		_ = lastErr
	}
}
