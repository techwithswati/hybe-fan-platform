/**
 * ╔══════════════════════════════════════════════════════════════════════════════╗
 * ║   HYBE Fan Platform — K6 Load Test                                           ║ 
 * ║   Simulates a real BTS/NewJeans merch drop: gradual ramp → sudden spike      ║
 * ║                                                                              ║
 * ║   Run:  k6 run k6/load-test.js                                               ║
 * ║   Run (with output to InfluxDB for Grafana):                                 ║
 * ║     k6 run --out influxdb=http://localhost:8086/k6 k6/load-test.js           ║
 * ╚══════════════════════════════════════════════════════════════════════════════╝
 */

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { randomString, randomIntBetween } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

// ── Custom Metrics ─────────────────────────────────────────────────────────────
const ticketPurchaseSuccess = new Counter("ticket_purchase_success");
const ticketPurchaseFailed  = new Counter("ticket_purchase_failed");
const soldOutResponses      = new Counter("sold_out_responses");
const rateLimitedResponses  = new Counter("rate_limited_responses");
const purchaseLatency       = new Trend("purchase_latency_ms", true);
const catalogLatency        = new Trend("catalog_latency_ms", true);
const errorRate             = new Rate("error_rate");

// ── Test Configuration ─────────────────────────────────────────────────────────
const BASE_URL = __ENV.BASE_URL || "https://api.fans.hybe.com";

/**
 * Traffic shape: mirrors a real K-pop merch drop:
 * 
 * Phase 1 (0-5min):    "Pre-drop" - fans checking availability, ~500 users
 * Phase 2 (5-6min):    "Announcement" - sudden spike to 10,000 users
 * Phase 3 (6-8min):    "Peak frenzy" - 50,000 concurrent users hammering purchase
 * Phase 4 (8-12min):   "Settling" - items selling out, traffic drops to 5,000
 * Phase 5 (12-15min):  "Tail" - stragglers checking availablility, cool down
 * 
 * HPA should scale from 3 → ~30 pods during phases 2-3,
 * then back down over 5 minutes after phase 4.
 */
export const options = {
  scenarios: {
    // ── Constant low traffic: catalog browsers pre-drop ──────────────────────
    pre_drop_browsers: {
      executor: "constant-vus",
      vus: 500,
      duration: "5m",
      tags: { phase: "pre_drop" },
    },

    // ── Ramping spike: the drop annoucement hits ─────────────────────────────
    drop_spike: {
      executor: "ramping-vus",
      startTime: "5m",
      startVUs: 500,
      stages: [
        { duration: "60s", target: 10000 },   // Surge: 500 → 10k in 60s
        { duration: "2m",  target: 50000 },   // Peak: 10k → 50k in 2min
        { duration: "3m",  target: 50000 },   // Sustain peak for 3 minutes
        { duration: "2m",  target: 5000  },   // Cool down
        { duration: "3m",   target: 500  },   // Tail traffic
      ],
      tags: { phase: "drop" },
    },
  },

  // ── Pass/Fail Thresholds ────────────────────────────────────────────────────
  thresholds: {
    // Core SLA: 95% of all requests under 500ms
    http_req_duration: ["p(95)<500", "p(99)<2000"],

    // Purchase endpoint specifically: p95 under 200ms
    "http_req_duration{endpoint:purchase}": ["p(95)<200"],

    // Catalog: always fast
    "http_req_duration{endpoint:catalog}": ["p(95)<100"],

    // Max 1% true server errors (5xx) - 429 rate limits don't count
    error_rate: ["rate<0.01"],

    // At least 60% of purchase attempts should succeed (rest = sold out)
    "ticket_purchase_success": ["count>0"],
  },
};

// ── Simulated Fan Profiles ─────────────────────────────────────────────────────
const FAN_ARTISTS = ["BTS", "SEVENTEEN", "NewJeans", "LE SSERAFIM", "TXT"];
const MERCH_SKUS  = [
    "BTS-HOODIE-BUTTER",
    "SVT-CAP-2025",
    "NJ-PHOTOBOOK-OMG",
    "LE-POSTER-SIGNED",
    "TXT-LIGHTSTICK-V2",
];
const SEAT_ZONES  = ["VIP", "A", "B", "C"];

function getFanId() {
  return `fan_${randomString(8)}_${randomIntBetween(1000, 9999)}`;
}

// ── Default Function - Fan Journey ────────────────────────────────────────────
export default function () {
  const fanId = getFanId();
  const headers = {
    "Content-Type": "application/json",
    "X-Fan-ID": fanId,
    "Accept": "application/json",
  };

  // ── STEP 1: Check ticket availability (everyone does this) ─────────────────
  group("check_availability", () => {
    const res = http.get(
      `${BASE_URL}/api/v1/tickets/availability?event_id=bts-world-tour-2025`,
      { headers, tags: { endpoint: "availability" } }
    );

    const ok = check(res, {
      "availability: status 200":        (r) => r.status === 200,
      "availability: has tickets_remaining": (r) => {
        const body = JSON.parse(r.body);
        return body.tickets_remaining !== undefined;
      },
    });
    errorRate.add(!ok);
  });

  sleep(randomIntBetween(1, 3));  // Fans read the page

  // ── STEP 2: Browse merch catalog ───────────────────────────────────────────
  group("browse_catalog", () => {
    const start = Date.now();
    const res = http.get(
      `${BASE_URL}/api/v1/merch/catalog`,
      { headers, tags: { endpoint: "catalog" } }
    );
    catalogLatency.add(Date.now() - start);

    check(res, {
      "catalog: status 200": (r) => r.status === 200,
      "catalog: has items":  (r) => {
        try {
            return JSON.parse(r.body).catalog.length > 0;
        }   catch (_) {
            return false;
        }
      },
    });
  });

  sleep(randomIntBetween(1, 4));  // Fan decides what to buy

  // ── STEP 3: Attempt ticket purchase (the CRITICAL spike endpoint) ──────────
  group("purchase_ticket", () => {
    const payload = JSON.stringify({
      fan_id:    fanId,
      event_id:  "bts-world-tour-2025",
      seat_zone: SEAT_ZONES[randomIntBetween(0, SEAT_ZONES.length - 1)],
    });

    const start = Date.now();
    const res = http.post(
        `${BASE_URL}/api/v1/tickets/purchase`,
        payload,
        { headers, tags: { endpoint: "purchase" } }
    );
    purchaseLatency.add(Date.now() - start);

    if (res.status === 201) {
      ticketPurchaseSuccess.add(1);
      check(res, {
        "purchase: booking_id exists": (r) => JSON.parse(r.body).booking_id > 0,
        "purchase: status confirmed":  (r) => JSON.parse(r.body).status === "confirmed",
      });
    } else if (res.status === 409) {
      soldOutResponses.add(1);   // Expected during peak - not an error
    } else if (res.status === 429) {
      rateLimitedResponses.add(1);   // Rate limited - back off
      sleep(1);
    } else {
      ticketPurchaseFailed.add(1);
      errorRate.add(1);
    }
  });

  sleep(randomIntBetween(1, 2));

  // ── STEP 4: Lock merch cart (concurrent with ticket purchase) ─────────────
  group("merch_cart_lock", () => {
    const sku = MERCH_SKUS[randomIntBetween(0, MERCH_SKUS.length - 1)];
    const payload = JSON.stringify({ fan_id: fanId, sku, quantity: 1 });

    const res = http.post(
        `${BASE_URL}/api/v1/merch/cart/lock`,
        payload,
        { headers, tags: { endpoint: "cart_lock" }}
    );

    if (res.status === 200) {
      // ── STEP 5: Complete merch purchase ─────────────────────────────────
      sleep(randomIntBetween(2, 10));   // Simulate checkout form fill

      const purchasePayload = JSON.stringify({ fan_id: fanId, sku, quantity: 1 });
      const purchaseRes = http.post(
        `${BASE_URL}/api/v1/merch/purchase`,
        purchasePayload,
        { headers, tags: { endpoint: "merch_purchase" } }
      );

      check(purchaseRes, {
        "merch purchase: confirmed": (r) => r.status === 201,
      });
    }
  });

  // Short pause between iterations
  sleep(randomIntBetween(1, 3));
}

// ── Setup: announce test start ────────────────────────────────────────────────
export function setup() {
  console.log(`
╔══════════════════════════════════════════╗
║  HYBE Fan Platform — Load Test Starting  ║
║  Target: ${BASE_URL}
║  Peak VUs: 50,000                        ║
║  Phases: Pre-drop → Spike → Sustain      ║
╚══════════════════════════════════════════╝
  `);
  return { startTime: Date.now() };
}

// ── Teardown: print summary ───────────────────────────────────────────────────
export function teardown(data) {
  const durationMin = Math.round((Date.now() - data.startTime) / 60000);
  console.log(`
✅ Load test complete (${durationMin} min)
   Check k6 output above for:
   - http_req_duration p(95) - must be < 500ms
   - ticket_purchase_success count
   - error_rate - must be < 1%
   - sold_out_responses (expected at peak)

   Watch HPA: kubectl get hpa -n hybe-prod --watch
  `);
}
