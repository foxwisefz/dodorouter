# Dodo Router Website — Design & Content Specification

## Project Overview

**Product:** Dodo Router — an OpenAI-compatible LLM proxy with automatic fallback across providers. Drop-in replacement: change your base URL, then manage routing chains, providers, and models from a dashboard.

**Live URL:** https://dodorouter.com  
**API Base:** https://api.dodorouter.com  
**GitHub:** https://github.com/foxwise-ai/dodorouter  
**Email:** support@dodorouter.com  

## Tech Stack

- **Static Site Generator:** Eleventy v3 (`@11ty/eleventy`)
- **CSS:** Tailwind CSS v4 (`@tailwindcss/cli` + `tailwindcss` v4.1)
- **Templates:** Nunjucks (`.njk`)
- **Fonts:** Google Fonts — Instrument Serif (display/headings, including italic) + Inter (body text)
- **Build:** `concurrently` for parallel dev servers
- **No JS framework** — pure static HTML, CSS animations only

## Project Structure

```
website/
├── eleventy.config.js          # Eleventy config: passthrough, filters, dir layout
├── package.json                # Scripts: dev, build, clean
├── src/
│   ├── _data/site.json         # Site name, description, URL
│   ├── _layouts/base.njk       # HTML shell: fonts, meta, OG tags, header/footer includes
│   ├── _includes/header.njk    # Fixed navbar
│   ├── _includes/footer.njk    # Footer with links
│   ├── css/app.css             # Tailwind v4 imports, @theme tokens, custom utilities
│   ├── index.njk               # Single-page homepage (all sections)
│   └── assets/                 # Static: favicon, logo PNGs, OG image
```

## Page Layout

The homepage is a single-page layout. The hero section is `h-screen` (fills exactly 100vh) with `overflow-hidden` — the dashboard mockup overflows toward the bottom and is clipped. Below the fold there is no additional content (currently a single-screen landing page).

The `<body>` uses `min-h-screen bg-background text-foreground antialiased font-body`.

## Fonts & Design Tokens (app.css)

### Font imports (in base.njk `<head>`)

```html
<link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Inter:wght@400;500;600&display=swap" rel="stylesheet" />
```

### Tailwind v4 @theme block

```css
@theme {
  --color-background: hsl(0, 0%, 100%);           /* white */
  --color-foreground: hsl(210, 14%, 17%);          /* dark charcoal */
  --color-primary: hsl(210, 14%, 17%);
  --color-primary-foreground: hsl(0, 0%, 100%);
  --color-secondary: hsl(0, 0%, 96%);
  --color-secondary-foreground: hsl(0, 0%, 9%);
  --color-muted: hsl(0, 0%, 96%);
  --color-muted-foreground: hsl(184, 5%, 55%);     /* slate gray */
  --color-accent: hsl(239, 84%, 67%);              /* indigo/blue */
  --color-accent-foreground: hsl(0, 0%, 100%);
  --color-border: hsl(0, 0%, 90%);
  --color-ring: hsl(239, 84%, 67%);
  --color-go: hsl(142, 71%, 45%);                  /* green/success */
  --color-go-foreground: hsl(0, 0%, 100%);
  --color-warn: hsl(38, 92%, 50%);                 /* amber/warning */
  --color-warn-foreground: hsl(0, 0%, 9%);
  --color-error: hsl(0, 84%, 60%);                 /* red/error */
  --color-error-foreground: hsl(0, 0%, 100%);
  --font-display: 'Instrument Serif', serif;
  --font-body: 'Inter', ui-sans-serif, system-ui, sans-serif;
  --shadow-dashboard: 0 25px 80px -12px rgba(0, 0, 0, 0.08), 0 0 0 1px rgba(0, 0, 0, 0.06);
}
```

### Custom CSS Utilities

| Class | Purpose |
|---|---|
| `animate-fade-up` | Fade-up entrance animation with CSS custom properties for `--fade-y`, `--fade-duration`, `--fade-delay` |
| `animate-soft-pulse` | Gentle opacity pulse (2s infinite) |
| `dashboard-mockup` | Sets `font-body`, `text-[11px]`, `select-none`, `pointer-events-none` on dashboard UI |
| `frosted-glass` | White semi-transparent background + blur + shadow + border (glassmorphism) |
| `video-overlay` | Gradient overlay from transparent to white (makes video background readable) |

### Animations

- `fade-up`: from `opacity: 0; translateY(var(--fade-y, 16px))` to `opacity: 1; translateY(0)` using `cubic-bezier(0.16, 1, 0.3, 1)`
- `soft-pulse`: oscillates opacity between 1 and 0.5 over 2s

## Navbar (header.njk)

- `flex items-center justify-between px-6 md:px-12 lg:px-20 py-5 font-body relative z-50`
- **Left:** Dodo Router horizontal logo image (`h-7`)
- **Center (hidden mobile):** Nav links — Features, Providers, Pricing, GitHub — `text-sm text-muted-foreground hover:text-foreground` with `gap-8`
- **Right:** "Log In" link (hidden mobile) + "Get Started" rounded-full primary CTA button
- Links to `/#features`, `/#providers`, `/#pricing`, `https://github.com/foxwise-ai/dodorouter`
- CTA links to `https://api.dodorouter.com/users/register`

## Hero Section (index.njk)

The hero is a full-viewport section with a video background:

```
<section class="relative h-screen flex flex-col bg-background overflow-hidden">
```

### Background Video

- Fullscreen muted autoplay loop video, `absolute inset-0 w-full h-full object-cover z-0`
- Video URL: `https://d8j0ntlcm91z4.cloudfront.net/user_38xzZboKViGWJOttwIXH07lWA1P/hf_20260319_015952_e1deeb12-8fb7-4071-a42a-60779fc64ab6.mp4`
- White gradient overlay (`video-overlay` class) on top at `z-[1]` for readability

### 1. Badge (top)

- `animate-fade-up` with `--fade-y: 10px; --fade-duration: 0.5s`
- Green pulsing dot + "Now with streaming & tool call support"
- `inline-flex items-center gap-1.5 rounded-full border border-border bg-background px-4 py-1.5 text-sm text-muted-foreground`

### 2. Headline

- `animate-fade-up` with `--fade-y: 16px; --fade-duration: 0.6s; --fade-delay: 0.1s`
- `text-center font-display text-5xl md:text-6xl lg:text-[5rem] leading-[0.95] tracking-tight text-foreground max-w-xl`
- Text: "The LLM proxy with _automatic_ fallback" — "automatic" in `<em>` (Instrument Serif italic)

### 3. Subheadline

- `animate-fade-up` with delay 0.2s
- `mt-4 text-center text-base md:text-lg text-muted-foreground max-w-[650px] leading-relaxed font-body`
- Text: "Drop-in OpenAI-compatible proxy that routes requests across providers. Change your base URL once — then swap providers, reorder chains, and adjust models on the fly from the dashboard."

### 4. CTA Buttons

- `animate-fade-up` with delay 0.3s
- **Primary:** "Get Started Free" — `rounded-full bg-primary px-6 py-3 text-sm font-medium font-body text-primary-foreground` — links to registration
- **Secondary:** GitHub icon button — `h-11 w-11 rounded-full bg-background shadow-[0_2px_12px_rgba(0,0,0,0.08)]` with inline GitHub SVG — links to repo

### 5. Dashboard Preview (custom coded, NOT an image)

- `animate-fade-up` with `--fade-y: 30px; --fade-duration: 0.8s; --fade-delay: 0.5s`
- Container: `mt-8 w-full max-w-5xl px-4 md:px-6`
- Frosted glass wrapper: `frosted-glass rounded-2xl overflow-hidden p-3 md:p-4`
- Inner dashboard: `dashboard-mockup rounded-xl bg-white/90 overflow-hidden`

#### Dashboard Internals

**Top Bar:**
- Left: "D" logo box (accent bg) + "DodoRouter" + chevron
- Center: Search bar with `⌘K` shortcut badge
- Right: "Dashboard" label + bell icon with notification dot + "DR" avatar

**Sidebar (w-40, hidden on mobile):**
- Active: Dashboard (accent highlight)
- Items with badges: Requests (1.2K badge), Routers, Costs, API Keys
- Providers section: z.ai (amber "Z" badge), Moonshot (sky "M" badge)
- Settings section: Settings with gear icon

**Main Content (bg-secondary/30):**

*Stats Row:*
- "Router Overview" / "my-production-router" with green "Live" status pill

*4 Stat Cards (grid 2-col mobile, 4-col desktop):*
- Total Requests: 12,847 (+14.2% green)
- Success Rate: 99.7% (23 fallbacks recovered)
- p95 Latency: 340ms (-8% green)
- Total Cost: $12.84 (4.2M tokens)

*Two Side-by-Side Cards:*
1. **Request Volume Chart** — SVG area chart with cubic Bezier curve, accent gradient fill, "Last 24h" label
2. **Routing Chain** — 3 steps:
   - z.ai / GLM-5.1 → Primary (green)
   - Moonshot / Kimi-K2 → Fallback (amber)
   - z.ai / GLM-5 → Last Resort (red)

*Request Log Table:*
- Columns: Time, Status, Provider/Model, Tokens, Latency
- 4 rows with realistic data:
  - 14:23:01 — success — z.ai / GLM-5 — 1,247 tokens — 285ms
  - 14:22:58 — fallback (amber) — z.ai → Moonshot / Kimi-K2 — 892 tokens — 1,240ms
  - 14:22:55 — success — z.ai / GLM-5.1 — 2,103 tokens — 412ms
  - 14:22:51 — success — Moonshot / Kimi-K2.5 — 567 tokens — 198ms
- Streaming indicator with pulsing accent dot

## Footer (footer.njk)

- `border-t border-border bg-background`
- Left: Dodo Router logo + tagline "OpenAI-compatible LLM proxy with automatic fallback."
- Right: Links — Features, Providers, Pricing, Terms
- Bottom: "© 2026 Foxwise AI. All rights reserved." (dynamic year via Nunjucks filter)

## Key External Links

| Label | URL |
|---|---|
| Register | https://api.dodorouter.com/users/register |
| Log In | https://api.dodorouter.com/users/log-in |
| Terms | https://api.dodorouter.com/terms |
| GitHub | https://github.com/foxwise-ai/dodorouter |
| Website | https://dodorouter.com |

## Development Commands

| Command | Description |
|---|---|
| `npm run dev` | Concurrent CSS watch + Eleventy serve |
| `npm run build` | Build CSS (Tailwind minify) then Eleventy |
| `npm run clean` | Remove `_site` directory |

## Eleventy Configuration

- Input: `src/`, Output: `_site/`
- Includes: `src/_includes/`, Layouts: `src/_layouts/`, Data: `src/_data/`
- Template formats: `html`, `njk`, `md`
- Passthrough copy: `src/assets/`
- Custom filter: `date` (returns year from "now" or date string)

## Tailwind CSS v4 Setup

```css
@import "tailwindcss";
@source "../src";
```

- No `tailwind.config.js` — uses v4 CSS-first config with `@theme` block
- Custom utilities defined via `@utility` directive
- Animations defined via `@keyframes`
- Source scanning points to `../src` (relative to `src/css/app.css`)

## Key Design Decisions

- **Single-page, single-screen:** Hero fills 100vh, dashboard clipped by `overflow-hidden`
- **No dark mode** — light only
- **Video background** with white gradient overlay for readability
- **Frosted glass** dashboard preview (not a screenshot — hand-coded HTML)
- **All icons are inline SVGs** — no icon library dependency
- **No JavaScript framework** — pure CSS animations via custom properties
- **Status colors are semantic:** go (green), warn (amber), error (red) — matching the router's fallback states
- **Dashboard mockup uses real Dodo Router data:** routing chains, provider names, request logs with fallback visualization
- **The "fallback" row in the request log shows strikethrough on failed provider** with arrow to fallback provider

## Content & Copy Guidelines

- **Tone:** Developer-friendly, technical but accessible. No hype.
- **Voice:** Direct, confident. "Drop-in", "automatic", "on the fly"
- **Key messages:**
  - OpenAI-compatible (drop-in replacement)
  - Automatic fallback across providers
  - Manage everything from a dashboard
  - Streaming and tool call support
- **Design aesthetic:** Clean, professional, light. Frosted glass dashboard gives a premium feel without being flashy.
