import { readFileSync, writeFileSync } from "node:fs";
import { buildSubgraphConfig, renderSubgraphYaml } from "../src/manifest-config.mjs";

const manifest = JSON.parse(readFileSync(new URL("../fixtures/localhost-deployment.json", import.meta.url), "utf8"));
const authority = JSON.parse(readFileSync(new URL("../../contracts/artifacts.json", import.meta.url), "utf8"));
const config = buildSubgraphConfig(manifest, authority);
const yaml = renderSubgraphYaml(config);

writeFileSync(new URL("../subgraph.yaml", import.meta.url), yaml, "utf8");
