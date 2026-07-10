import anchor from "markdown-it-anchor";
import fs from "node:fs";
import path from "node:path";

export default function (eleventyConfig) {
  // Copy static assets
  eleventyConfig.addPassthroughCopy("src/assets");

  // Watch for CSS changes
  eleventyConfig.addWatchTarget("src/css/");

  // Add a date filter for Nunjucks
  eleventyConfig.addFilter("date", function (value, format) {
    const date = value === "now" ? new Date() : (value instanceof Date ? value : new Date(value));
    return date.getFullYear().toString();
  });

  // Give every docs heading a stable, linkable id (h2/h3 only — h1 is the
  // page title and doesn't need one).
  eleventyConfig.amendLibrary("md", (mdLib) =>
    mdLib.use(anchor, {
      level: [2, 3],
      slugify: (s) =>
        String(s)
          .trim()
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/(^-|-$)/g, ""),
      permalink: anchor.permalink.linkInsideHeader({
        placement: "before",
        symbol: "#",
        class: "header-anchor",
        ariaHidden: true,
      }),
    })
  );

  // Wrap every rendered table in a scroll container so wide reference tables
  // don't blow out the viewport on narrow screens.
  eleventyConfig.amendLibrary("md", (mdLib) => {
    const defaultOpen =
      mdLib.renderer.rules.table_open ||
      ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));
    const defaultClose =
      mdLib.renderer.rules.table_close ||
      ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options));

    mdLib.renderer.rules.table_open = (tokens, idx, options, env, self) =>
      '<div class="docs-table-scroll">' + defaultOpen(tokens, idx, options, env, self);
    mdLib.renderer.rules.table_close = (tokens, idx, options, env, self) =>
      defaultClose(tokens, idx, options, env, self) + "</div>";
  });

  // Docs pages: everything under src/docs/, ordered by front-matter `order`.
  // This is the single source of truth the sidebar, prev/next links, and
  // llms-full.txt are all built from.
  eleventyConfig.addCollection("docsPages", (api) =>
    api.getFilteredByGlob("src/docs/**/*.md").sort((a, b) => (a.data.order ?? 0) - (b.data.order ?? 0))
  );

  // Extract {level, id, text} for every anchored heading in rendered HTML —
  // powers the "On this page" rail without a separate TOC plugin.
  eleventyConfig.addFilter("headings", (html) => {
    if (typeof html !== "string") return [];
    const re = /<h([23])[^>]*\sid="([^"]+)"[^>]*>([\s\S]*?)<\/h\1>/g;
    const out = [];
    let m;
    while ((m = re.exec(html))) {
      out.push({
        level: Number(m[1]),
        id: m[2],
        text: m[3]
          .replace(/<a class="header-anchor"[\s\S]*?<\/a>/, "")
          .replace(/<[^>]+>/g, "")
          .trim(),
      });
    }
    return out;
  });

  eleventyConfig.addFilter("findIndexByUrl", (arr, url) =>
    Array.isArray(arr) ? arr.findIndex((item) => item.url === url) : -1
  );

  // "/docs/quickstart/" -> "/docs/quickstart.md" ; "/docs/" -> "/docs.md"
  eleventyConfig.addFilter("mdTwinUrl", (url) => {
    if (!url) return "";
    const trimmed = url.endsWith("/") ? url.slice(0, -1) : url;
    return trimmed + ".md";
  });

  // Raw markdown body (front matter stripped) of a docs page, keyed by its
  // input path — this is what llms-full.txt and each page's .md twin route
  // are built from, so the "view as markdown" version is always the exact
  // source of truth, not a lossy re-derivation from rendered HTML.
  eleventyConfig.addFilter("rawMarkdownBody", (inputPath) => {
    const abs = path.resolve(inputPath);
    const raw = fs.readFileSync(abs, "utf8");
    return raw.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "").trim();
  });

  return {
    dir: {
      input: "src",
      output: "_site",
      includes: "_includes",
      layouts: "_layouts",
      data: "_data",
    },
    templateFormats: ["html", "njk", "md", "txt"],
    htmlTemplateEngine: "njk",
    markdownTemplateEngine: "njk",
  };
}
