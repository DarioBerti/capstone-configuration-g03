# k6 — money-path load generator

`money-path.js` drives steady traffic on the money path so the SLIs in `docs/slo.md` are live and the
chaos experiments in `platform/chaos-mesh/` run under load. It encodes the SLO semantics directly: the
intake `POST /api/orders` is accepted on 200/201/202, a **429 is load shedding** (reported, never a
failure), and only 5xx/transport errors count against the error budget.

## Prerequisites
- [k6](https://k6.io/docs/get-started/installation/) installed locally.
- A reachable ingress host (`BASE_URL`), and — since the services are OAuth2 resource servers — a token.

## Auth (pick one)
- **Pre-fetched token (most portable):** `-e TOKEN=<jwt>`.
- **Password grant** (a seeded test user via the public `eurotransit-frontend` client — works only where
  `directAccessGrants` is enabled, i.e. kind/dev): `-e KC_TOKEN_URL=<token-endpoint> -e KC_USERNAME=<u> -e KC_PASSWORD=<p>`.
- **Client credentials** (a confidential client, e.g. `orders-svc`): `-e KC_TOKEN_URL=<...> -e KC_CLIENT_ID=orders-svc -e KC_CLIENT_SECRET=<secret>`.
- No token → runs unauthenticated (secured endpoints return 401; useful only to smoke the public read path).

The token endpoint is `https://<keycloak-host>/realms/eurotransit/protocol/openid-connect/token`.

## Run
```bash
k6 run -e BASE_URL=https://158.158.71.17.sslip.io \
       -e KC_TOKEN_URL=https://auth.g03.cpo2026.it/realms/eurotransit/protocol/openid-connect/token \
       -e TOKEN="$JWT" \
       -e VUS=10 -e DURATION=5m \
       platform/k6/money-path.js
```
Knobs (all optional): `VUS` (steady users, default 10), `DURATION` (steady hold, default 5m),
`ORDERS_RATIO` (share of iterations that place an order vs browse, default 0.3),
`ORDER_BODY` (override the request JSON without editing the file).

## ⚠ Order payload depends on the deployed image
The default `ORDER_BODY` matches the **reworked** contract on application `dev`:
`PlaceOrderRequest(tripCode, qty)` — the buyer identity comes from the JWT `sub` (not the body), and an
optional `Idempotency-Key` header dedupes retries. **But the cluster currently runs the PRE-rework image**
(app `main` @22ce722) until `dev → main` lands and CI bumps the image tags. If you load-test that older
image, override the body to its contract: `-e ORDER_BODY='{...}'`. The intake returns 202 even for an
unknown trip code (the async saga rejects later), so it is enough for intake-SLO load; seed real seats for
a full money-path success run.

## How it ties to the rest of Phase 4
- The k6 **thresholds** (`orders_intake_ms p99<300`, `orders_intake_errors rate<0.01`) are a client-side
  *proxy* of the SLOs; the **authoritative** SLI is the server-side `http_server_requests_seconds` in
  Prometheus (the `eurotransit-checkout-slo` rule). Use k6 for a fast signal, Prometheus for the verdict.
- Run k6 **before and during** each chaos experiment so the dashboards have a steady baseline to deviate
  from, then capture the deviation + recovery as the experiment's evidence.
