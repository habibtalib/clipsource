# ClipSource Cloud backend (Supabase)

ClipSource Cloud is a Supabase project plus Stripe. Sync is end-to-end encrypted. The server stores:

- AES-GCM ciphertext (`clips.payload`), HMAC hashes and timestamps;
- an opaque random `device_id` on each row;
- the account's device list (name and kind). This is plaintext account metadata, shown on the account page.

| Path | What |
|---|---|
| `migrations/20261101000000_sync.sql` | `clips`, `sync_keys`, RLS, realtime |
| `migrations/20261101010000_cloud.sql` | `plan_limits`, `profiles`, `devices`, device-gated clip writes, RPCs, hourly retention job (pg_cron) |
| `migrations/20261101020000_hardening.sql` | devices bound to auth sessions, removal revokes the session, quotas, tombstone guard, no DELETE fan-out in realtime |
| `functions/billing-checkout` | Stripe Checkout session for Pro (user JWT) |
| `functions/billing-portal` | Stripe Billing Portal session (user JWT) |
| `functions/stripe-webhook` | Stripe events to `profiles.plan` (Stripe-Signature, no JWT) |
| `functions/_shared` | Stripe REST + signature check, PostgREST helpers, event mapping, Deno tests |

Plans live in `plan_limits`:

- **free:** 2 Macs, 7 days of synced history, 5,000 synced entries.
- **pro:** unlimited Macs, 365 days of synced history, 50,000 synced entries.

Both plans allow 3 web viewers (`web_device_limit`); they never count toward the Mac limit. To change a limit, edit those rows. Do not change the code.

The site URL `https://clipsource.app` is a placeholder. Replace it everywhere below with the real domain.

## 1. Create the project

1. Create a project at <https://supabase.com/dashboard>. Note the **project ref**, the **Project URL** and the **anon** key
   (Project Settings → API). Never put the `service_role` key in a client.
2. Apply the schema:
   ```bash
   supabase login
   supabase link --project-ref <project-ref>
   supabase db push
   ```
   Or paste both migration files, in order, into the **SQL Editor**.
3. Check that the cron job exists: **Integrations → Cron** shows `clipsource-prune-expired-clips` (hourly). If pg_cron
   was not enabled, enable it under **Database → Extensions** and run the migration's last block again.

## 2. Sign-in providers

1. **Authentication → Sign In / Providers**: enable **GitHub** and **Google** and enter each provider's client ID and secret.
   Register this callback URL with GitHub and Google: `https://<project-ref>.supabase.co/auth/v1/callback`.
2. **Authentication → URL Configuration**:
   - Site URL: `https://clipsource.app`
   - Redirect URLs:
     - `clipsource://auth-callback` (Mac app)
     - `https://clipsource.app/account`
     - `https://clipsource.app/app`
     - `http://localhost:8000/` (optional, local site development)

## 3. Stripe

Use test mode first, then repeat in live mode.

1. **Product catalog**: create the product "ClipSource Pro" with two recurring prices, monthly ($3) and yearly ($24). Copy both
   price IDs (`price_...`).
2. **Settings → Billing → Customer portal**: activate the portal. Allow cancelling and switching between the two prices.
3. **Developers → Webhooks → Add endpoint**:
   - URL: `https://<project-ref>.supabase.co/functions/v1/stripe-webhook`
   - Events: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`,
     `customer.subscription.deleted`
   - Copy the signing secret (`whsec_...`).

## 4. Edge Functions

```bash
cp supabase/functions/.env.example supabase/functions/.env   # fill in; the file is gitignored
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy billing-checkout
supabase functions deploy billing-portal
supabase functions deploy stripe-webhook
```

| Secret | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_test_...` / `sk_live_...` |
| `STRIPE_WEBHOOK_SECRET` | signing secret from step 3 |
| `STRIPE_PRICE_MONTH`, `STRIPE_PRICE_YEAR` | price IDs from step 3 |
| `SITE_URL` | `https://clipsource.app` (Checkout and Portal return to `/account`) |
| `ALLOW_LOCALHOST` | optional, `1` only for local development: also allow `http://localhost` origins (CORS) |
| `STRIPE_API_BASE` | optional, tests only: base URL of a local Stripe stand-in |

Supabase injects `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`; do not set them.

All three functions run with `verify_jwt = false` (`config.toml`). The gateway's JWT check rejects the ES256 tokens
issued with asymmetric signing keys. The billing functions authenticate the caller themselves through
`/auth/v1/user`. The webhook accepts only requests signed with `STRIPE_WEBHOOK_SECRET`, within 5 minutes.

Test the webhook with the Stripe CLI: `stripe trigger checkout.session.completed`. Better: run a test-mode
checkout from the account page with card `4242 4242 4242 4242`. Then check **Table Editor → profiles**: `plan` should be `pro`.

## 5. Clients

Put the Project URL and anon key into:

- the Mac app: `Sources/ClipCore/Sync/ClipSourceCloud.swift`, or the `ClipSourceSupabaseURL` / `ClipSourceSupabaseAnonKey`
  Info.plist values set by `Scripts/bundle-app.sh`;
- the website: `site/config.js`.

## Operations

- **Grant Pro manually** (SQL Editor): `update profiles set plan = 'pro' where user_id = '<uuid>';`. A later Stripe event
  overwrites this for users who have a subscription.
- **Plan source:** the webhook never trusts a single event. It lists all of the customer's subscriptions
  (`GET /v1/subscriptions?status=all`). The user is Pro if any of them is active or trialing.
  - Checkout refuses with 409 `already_subscribed` while one is active, trialing or past due.
- **Event order:** `profiles.stripe_event_at` holds the `created` time of the newest subscription event applied.
  If an older event arrives late, the webhook skips it (and still answers 200).
- **Downgrade:**
  - Devices are kept, but registering a new Mac over the Free limit fails with `device_limit`.
  - History older than 7 days is removed at the next hourly prune.
- **Retention** uses `least(created_at, updated_at)`, so a client-supplied future `created_at` does not keep a row
  forever.
- **Lost or stolen device:**
  1. Remove it on the account page (or in the Mac app's device list). This deletes its auth session and revokes its
     refresh token. Its access token can then no longer read or write synced history.
  2. Then **delete your synced data and set a new passphrase**. The device still holds the old key and anything it
     already downloaded.
- **Device binding:** a device ID belongs to the sign-in (auth session) that registered it.
  - Another live session using the same ID gets `device_in_use`.
  - After sign-out or removal, the ID can be registered again.
- **Quotas:**
  - payload at most 1.5 MiB;
  - `hash` must be 64 lowercase hex;
  - `sync_keys.iterations` must be between 100,000 and 10,000,000;
  - row cap per plan (`plan_limits.max_rows`; error `row_limit`, counted in `profiles.clip_count`).
- **Realtime** publishes only INSERT and UPDATE on `clips` (`supabase_realtime` with `publish = 'insert, update'`).
  Realtime does not filter DELETE events by RLS, so publishing them would tell every subscriber when any row was
  deleted. If the publication is ever recreated, run the last statement of the hardening migration again.
- **Run the prune now:** `select public.prune_expired_clips();` (returns rows deleted).

## Self-hosting

Anyone can run their own backend: create a Supabase project (hosted or self-hosted) and apply both migrations.
The Mac app then points at it under **Settings → Sync → Advanced: use my own Supabase server**. Billing is optional:

- Without the functions, every account stays on `free`.
- To lift the limits for everyone, make Free unlimited:
  `update plan_limits set device_limit = null, retention_days = 365 where plan = 'free';`
- Or grant Pro per user (see Operations).

## Local development

Needs the Supabase CLI and Docker.

```bash
supabase start                 # API http://127.0.0.1:54321, Studio http://127.0.0.1:54323
supabase db reset              # re-apply both migrations
supabase status -o env         # API_URL, ANON_KEY
supabase functions serve --env-file supabase/functions/.env   # functions at /functions/v1/<name>
deno test supabase/functions   # signature + event-mapping tests, no Stripe needed
supabase stop
```

Local config: email sign-up without confirmation (for test users). Redirects allowed:

- `clipsource://auth-callback`
- `http://localhost:8000/`

OAuth providers are off locally, so sign in with email and password. `Scripts/sync-e2e.sh` creates throwaway users.

Local Kong answers CORS with `Access-Control-Allow-Origin: *`. The hosted gateway returns the function's own headers.
Those allow `SITE_URL` only, plus localhost when `SITE_URL` is local or `ALLOW_LOCALHOST=1`.
