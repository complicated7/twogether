# Twogether

A shared "mood home" for couples, built as a set of static HTML pages with vanilla JavaScript and a [Supabase](https://supabase.com) backend (Auth, Postgres, Storage). Each couple signs up, pairs with their partner via a short invite code, and gets their own private mood-tracking dashboard, an interactive playground, and a shared photo gallery — isolated from every other couple using the site via Row Level Security.

## Pages

- **`login.html`** — Sign up or log in (Supabase Auth, email + password). Signing up without an invite code creates a new pair and hands you a short code to share with your partner; signing up *with* a code joins their pair instead.

- **`index.html`** — The main dashboard (requires login; redirects to `login.html` if you're not signed in).
  - Plays an intro animation on first visit (two eyes opening, styled as "the page waking up"), then reveals the page content. Skipped on repeat visits via a `localStorage` flag.
  - Dynamic header: both partners' real names, a live "days together" counter and month badge computed from the pair's start date.
  - **Mood picker**: 8 selectable moods (Happy, Tired, Sad, Mad, Hungry, Sleepy, Excited, Naughty). Selecting one changes the page's background gradient/accent colors, shows a matching message, spawns mood-themed floating particles, and saves your mood to your own row in Supabase (visible to your partner, not to anyone else).
  - **Partner section**: shows your partner's current mood read-only. If they haven't joined your pair yet, shows your invite code instead.
  - **Shared photo gallery**: either partner can upload a photo via a file picker; photos live in a private, pair-scoped Supabase Storage path and are shown via short-lived signed URLs. Click a photo to view it full-size; each photo has a two-tap delete button.
  - Links to `playground.html` and a log-out control.

- **`playground.html`** — An interactive page with a roaming animated face (just eyes and a mouth on a circle) that reflects *your partner's* current mood and reacts to touch:
  - Tapping elsewhere on the screen moves the face there.
  - Tapping the head (outside the zones below) makes her happy.
  - Tapping a cheek makes her irritated — she shakes and flees to a corner, and stays there (no auto-return).
  - Holding a cheek pinches it — a red, stretched mark on that side while held.
  - Booping the chin makes her shy — she ducks and fades briefly.
  - Dragging/patting across the face makes her blush.
  - Tapping the eyes or mouth is refused outright — a shake and a "not there!" bubble, no other effect.
  - Requires login; syncs to your partner's mood via Supabase polling every 4 seconds.

## Tech stack

- Static HTML, CSS, and vanilla JavaScript — no build step, bundler, or package manager.
- [Google Fonts](https://fonts.google.com/) — `Baloo 2` and `Quicksand`.
- [Supabase](https://supabase.com) for the backend, accessed via the `@supabase/supabase-js` client (loaded from the `esm.sh` CDN, no install needed):
  - **Auth** — email/password signup and login.
  - **Postgres tables**: `pairs` (id, invite code, since-date), `profiles` (links a user to their pair, holds their display name), `mood_state` (one row per user). All protected by Row Level Security — a user can only read/write rows belonging to their own pair, enforced via a `security definer` helper function (`auth_pair_id()`), not by client-side trust.
  - **Storage bucket (`gallery-photos`)** — private, RLS-scoped by a `{pair_id}/{filename}` path convention; access requires an authenticated session in the right pair.
  - **Rate limiting** — a DB trigger coalesces mood updates faster than 1/second per user, and another caps gallery uploads at 30/hour per pair.
  - The exact schema/policies/triggers live in [`supabase/migrations/0001_pairing_and_rls.sql`](supabase/migrations/0001_pairing_and_rls.sql).

## Installation / running locally

This is a purely static site — no build tooling or dependencies to install. To run it locally, serve the directory with any static file server, for example:

```bash
# Python
python -m http.server 8000

# Node (via npx)
npx serve .
```

Then open `http://localhost:8000/login.html` in a browser.

To stand up your own Supabase project for this site, run the migration in `supabase/migrations/0001_pairing_and_rls.sql` against a fresh project's SQL Editor, then swap the `SUPABASE_URL`/`SUPABASE_ANON_KEY` constants in `login.html`, `index.html`, and `playground.html`.

## Usage

1. Open `login.html` and sign up (first partner: leave the invite code blank; second partner: enter the code the first partner was given).
2. Watch the intro animation on `index.html` (or skip straight to the page on repeat visits).
3. Pick a mood — the page's theme and message update, and your partner can see it.
4. Visit `playground.html` to interact with a face reflecting your partner's mood.
5. Upload and view photos in the shared gallery.
