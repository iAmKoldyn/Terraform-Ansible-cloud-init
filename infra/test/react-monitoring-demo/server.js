const express = require("express");
const fs = require("fs");
const os = require("os");
const path = require("path");
const promClient = require("prom-client");

const app = express();
const port = Number(process.env.PORT || 3000);
const hostname = process.env.HOSTNAME || os.hostname();
const templatePath = path.join(__dirname, "index.html");
const template = fs.readFileSync(templatePath, "utf8");

let localPageViews = 0;

const register = new promClient.Registry();
register.setDefaultLabels({
  app: "page-view-demo",
  instance: hostname
});
promClient.collectDefaultMetrics({ register });

const pageViews = new promClient.Counter({
  name: "page_views_total",
  help: "Number of page views served by this replica",
  registers: [register]
});

function renderPage() {
  return template
    .replace(/__HOSTNAME__/g, hostname)
    .replace(/__PORT__/g, String(port))
    .replace(/__COUNT__/g, String(localPageViews))
    .replace(/__TIME__/g, new Date().toISOString());
}

app.get("/", (req, res) => {
  localPageViews += 1;
  pageViews.inc();
  res.type("html").send(renderPage());
});

app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    hostname,
    port
  });
});

app.get("/api/stats", (req, res) => {
  res.json({
    hostname,
    port,
    localPageViews
  });
});

app.get("/metrics", async (req, res) => {
  try {
    res.set("Content-Type", register.contentType);
    res.end(await register.metrics());
  } catch (error) {
    res.status(500).json({ error: String(error) });
  }
});

app.listen(port, () => {
  console.log(`page-view-demo listening on :${port} (${hostname})`);
});
