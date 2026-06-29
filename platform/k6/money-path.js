// k6 load generator for the EuroTransit money path. Produces the steady traffic the SLOs in docs/slo.md
// are defined over, and the background load the chaos experiments (platform/chaos-mesh) run under.
//
// It deliberately mirrors the SLO semantics:
//   - the synchronous intake POST /api/orders returns 202 (the saga is async) -> 200/201/202 are all "accepted";
//   - a 429 is LOAD SHEDDING (controlled refusal), NOT an error -> counted separately, never as a failure;
//   - only 5xx / connection errors count against the error budget.
//
// Run (example, against the AKS ingress; set your kube context / host first):
//   k6 run -e BASE_URL=https://158.158.71.17.sslip.io \
//          -e KC_TOKEN_URL=https://auth.g03.cpo2026.it/realms/eurotransit/protocol/openid-connect/token \
//          -e KC_USERNAME=<testuser> -e KC_PASSWORD=<pwd> \
//          -e VUS=10 -e DURATION=5m platform/k6/money-path.js
// Simpler: fetch a token yourself and pass it: `-e TOKEN=<jwt>`. Tune load with -e VUS / -e DURATION.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ---- configuration (all via -e env, with safe defaults) --------------------------------------------
const BASE_URL = __ENV.BASE_URL;                 // REQUIRED, e.g. https://<host>  (no trailing slash)
const VUS = Number(__ENV.VUS || '10');           // concurrent virtual users at steady state
const DURATION = __ENV.DURATION || '5m';         // steady-state hold (ramp up/down added around it)
const ORDERS_RATIO = Number(__ENV.ORDERS_RATIO || '0.3'); // share of iterations that POST an order vs browse

// Order request body. PLACEHOLDER — the domain model is being reworked (productId String -> Trip/Journey
// entities + UUIDs + a payer user), so the real OrderRequest DTO is a moving target. ALIGN THIS to the
// current contract, or override at runtime without editing the file: -e ORDER_BODY='{"...":"..."}'.
const ORDER_BODY = __ENV.ORDER_BODY || JSON.stringify({
  items: [{ productId: 'demo-seat', quantity: 1 }],
});

// ---- custom metrics --------------------------------------------------------------------------------
const shed429 = new Counter('orders_shed_429');        // controlled refusal — a FEATURE, reported, not failed
const intakeErrors = new Rate('orders_intake_errors'); // 5xx / network only
const intakeLatency = new Trend('orders_intake_ms', true);

// ---- thresholds: SLOs expressed as k6 checks (client-side PROXY) -----------------------------------
// NB: these are measured at the CLIENT (includes ingress/network), so they sit slightly above the
// authoritative server-side SLI (http_server_requests_seconds in Prometheus). They are a fast smoke
// signal during a run; the graded SLI is the Prometheus one. abortOnFail stays false so chaos runs
// are not killed by a transient breach — we WANT to observe breaches, not stop on them.
export const options = {
  scenarios: {
    money_path: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: VUS },   // ramp up
        { duration: DURATION, target: VUS }, // steady state (where SLIs are read)
        { duration: '30s', target: 0 },      // ramp down
      ],
      gracefulStop: '10s',
    },
  },
  thresholds: {
    orders_intake_ms: [{ threshold: 'p(99)<300', abortOnFail: false }],
    orders_intake_errors: [{ threshold: 'rate<0.01', abortOnFail: false }],
    'http_req_duration{name:catalog_browse}': [{ threshold: 'p(95)<500', abortOnFail: false }],
  },
};

// A 429 is an EXPECTED response (load shedding), so it must not inflate k6's built-in http_req_failed.
http.setResponseCallback(http.expectedStatuses(200, 201, 202, 429));

// ---- token acquisition (once, shared with all VUs) -------------------------------------------------
export function setup() {
  if (!BASE_URL) throw new Error('BASE_URL is required (e.g. -e BASE_URL=https://<host>)');

  if (__ENV.TOKEN) return { token: __ENV.TOKEN };           // simplest: a pre-fetched JWT
  const url = __ENV.KC_TOKEN_URL;
  if (!url) {
    console.warn('No TOKEN/KC_TOKEN_URL set -> running UNAUTHENTICATED; secured endpoints will return 401.');
    return { token: null };
  }
  // password grant (a seeded test user via the public eurotransit-frontend client, dev/kind only) if a
  // username is given; otherwise client_credentials (e.g. the confidential orders-svc client).
  const form = __ENV.KC_USERNAME
    ? { grant_type: 'password', client_id: __ENV.KC_CLIENT_ID || 'eurotransit-frontend',
        username: __ENV.KC_USERNAME, password: __ENV.KC_PASSWORD }
    : { grant_type: 'client_credentials', client_id: __ENV.KC_CLIENT_ID,
        client_secret: __ENV.KC_CLIENT_SECRET };
  if (__ENV.KC_CLIENT_SECRET) form.client_secret = __ENV.KC_CLIENT_SECRET; // confidential public-client edge case
  const res = http.post(url, form, { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
  if (res.status !== 200) throw new Error(`Keycloak token fetch failed: ${res.status} ${res.body}`);
  return { token: res.json('access_token') };
}

// ---- per-iteration workload ------------------------------------------------------------------------
export default function (data) {
  const authHeader = data.token ? { Authorization: `Bearer ${data.token}` } : {};

  if (Math.random() >= ORDERS_RATIO) {
    // browse traffic (bursty, public read path)
    http.get(`${BASE_URL}/api/catalog/products`, { tags: { name: 'catalog_browse' }, headers: authHeader });
  } else {
    // money-path intake (the SLO-bearing call)
    const res = http.post(`${BASE_URL}/api/orders`, ORDER_BODY, {
      tags: { name: 'orders_intake' },
      headers: { 'Content-Type': 'application/json', ...authHeader },
    });
    intakeLatency.add(res.timings.duration);
    if (res.status === 429) {
      shed429.add(1);                                   // controlled refusal — expected under overload, not an error
    } else {
      intakeErrors.add(res.status >= 500 || res.status === 0); // count only server/transport failures
      check(res, { 'intake accepted (200/201/202)': (r) => [200, 201, 202].includes(r.status) });
    }
  }
  sleep(0.5);
}
