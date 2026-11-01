# Vendored libraries

Served from this origin so the CSP can stay `script-src 'self'` (no CDN) for pages that handle the sync passphrase, key and plaintext.

## supabase-js 2.45.4

| | |
|---|---|
| File | `supabase-js-2.45.4.umd.js` = `package/dist/umd/supabase.js` from the npm tarball, unmodified |
| Source | `npm pack @supabase/supabase-js@2.45.4` |
| Tarball integrity (npm registry `dist.integrity`, verified) | `sha512-E5p8/zOLaQ3a462MZnmnz03CrduA5ySH9hZyL03Y+QZLIOO4/Gs8Rdy4ZCKDHsN7x0xdanVEWWFN3pJFQr9/hg==` |
| File sha256 | `8596965fe918e656600a1b568d3a168f5c0d3d22a600886bb6f44a6555db01e7` |
| File SRI (in the `<script integrity>` of `/app` and `/account`) | `sha384-0w2KAL2YHP6wKOkUDzkCDGgVvfmHnj02DHeQ6XcHOgTfFsGyonKOpShMH1x6nk9o` |
| License | MIT, `supabase-js-LICENSE` |

The UMD build defines `globalThis.supabase`; `site/supabase.js` reads `createClient` from it. The package's second UMD chunk (`591.supabase.js`) only loads the Node `ws` shim when the browser has no native `WebSocket`, so it is not vendored.

To verify or upgrade:

```bash
npm pack @supabase/supabase-js@<version>
npm view @supabase/supabase-js@<version> dist.integrity      # compare with:
echo "sha512-$(openssl dgst -sha512 -binary supabase-supabase-js-<version>.tgz | base64)"
tar xzf supabase-supabase-js-<version>.tgz
shasum -a 256 package/dist/umd/supabase.js
echo "sha384-$(openssl dgst -sha384 -binary package/dist/umd/supabase.js | base64)"
```

Then update the file name, this table, and the `src`/`integrity` of the script tag in `site/app/index.html` and `site/account/index.html`.
