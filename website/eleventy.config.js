export default function (eleventyConfig) {
  // Copy static assets
  eleventyConfig.addPassthroughCopy("src/assets");

  // Watch for CSS changes
  eleventyConfig.addWatchTarget("src/css/");

  // Add a date filter for Nunjucks
  eleventyConfig.addFilter("date", function (value, format) {
    const date = value instanceof Date ? value : new Date(value);
    return date.getFullYear().toString();
  });

  return {
    dir: {
      input: "src",
      output: "_site",
      includes: "_includes",
      layouts: "_layouts",
      data: "_data",
    },
    templateFormats: ["html", "njk", "md"],
    htmlTemplateEngine: "njk",
    markdownTemplateEngine: "njk",
  };
}
