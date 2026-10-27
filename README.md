# Bento

Bento runs OCR locally in the browser with PaddleOCR.js and ONNX Runtime Web. OCR does not call a paid API, and meal photos stay on the user's device. PaddleOCR model files are downloaded on first use; an internet connection is required for that initial model download. Recognized Chinese text is converted to Traditional Chinese locally before filling the form.

## Requirements

- Node.js 18 or newer
- Python 3 (only needed for the static server below)

## Run locally

```sh
npm install
npm run build
python3 server.py
```

Open `http://127.0.0.1:8001/`. To develop with Vite instead, run `npm run dev` and open the URL it prints. Vite proxies `/api` to the Python server on port 8001, so both processes must be running.

## Shared local testing

The Python server exposes `/api/state` and stores shared accounts and meal data in `bento-data.json` beside this file. Everyone testing through the same server URL reads and writes that shared file. The data stays on the host computer; it is not uploaded to a cloud database. Keep the Python server running while testers use the site. For the built site, forward port `8001` (for example, `ngrok http 8001`). When using Vite for development, forward port `5173` instead; Vite forwards API requests to Python. Share the resulting HTTPS URL. Changes from other testers appear within a few seconds.

The passwordless email and nickname flow is only a display identity. Anyone with the test URL can create or alter test records, so use this for trusted testers and non-sensitive data only. Back up `bento-data.json` before clearing or replacing test data.

## Use Supabase instead

1. Create a Supabase project and run `supabase/schema.sql` in its SQL Editor.
2. Copy `.env.example` to `.env.local`, then fill in the project URL and publishable key from the Supabase project settings. Keep the publishable key paired with the RLS policies in the SQL file; never put a service-role key in the frontend.
3. Restart `npm run dev`. When the Supabase settings are present, Bento reads and writes the shared state through Supabase instead of the local API.
4. To seed the cloud database from this local test data, run `npm run migrate:supabase` once after creating `.env.local`.

The initial schema stores Bento's current app model as one JSONB state row to keep this MVP migration small. Its policies allow public reads and writes for trusted testing; do not use that policy for private or production data. A Supabase database does not host the Vite website, so external testers will also need the frontend deployed to a static host.

## Publish a trusted test site with GitHub Pages

GitHub Pages can host this Vite frontend. On GitHub Free, the repository must be public, and the published site is open to anyone with its URL. The current email-and-nickname screen is only a display identity; anyone can enter another person's email, and the current Supabase policy allows visitors to read and change all shared test data. Use non-sensitive test data only.

1. Create a public GitHub repository and push this project to its `main` branch. `.env.local` and `bento-data.json` are excluded by `.gitignore`; do not add Supabase service-role or secret keys to the repository.
2. In the repository, open **Settings → Secrets and variables → Actions** and add repository secrets named `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. Use the Supabase project URL and publishable key (or legacy `anon` key), never the service-role key.
3. Open **Settings → Pages** and select **GitHub Actions** as the build and deployment source.
4. Push to `main` or run **Deploy to GitHub Pages** from the Actions tab. The workflow builds the site and deploys `dist`; GitHub shows the resulting URL in the Pages environment and workflow run.

The build uses the repository name as its project-site path, so it works at `https://<account>.github.io/<repository>/` without editing the base URL.

The static Python server can also run on Windows or Linux. Set `BENTO_HOST` and `PORT` when needed. Use HTTPS when hosting beyond localhost because browsers require a secure context for camera access.
