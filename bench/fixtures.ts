/**
 * bench/fixtures.ts — resolve PNG paths for bench/bench.ts and bench/bench-quality.ts
 *
 * Env: BENCH_FIXTURE — 次のいずれか（`npm run bench` / `npm run bench:quality`）
 *   default — bench_input.png（512×512）
 *   character_kanata / character_chika — 作者イラスト（長辺 1024px に整えた PNG）
 *   landscape_sunbeach / landscape_sea / landscape_study — 同上
 *
 * 旧エイリアス: character → character_chika, landscape_wide → landscape_sunbeach,
 *   landscape_soft → landscape_sea
 */

import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");

export const FIXTURE_IDS = [
  "default",
  "character_kanata",
  "character_chika",
  "landscape_sunbeach",
  "landscape_sea",
  "landscape_study",
] as const;
export type FixtureId = (typeof FIXTURE_IDS)[number];

const RELATIVE: Record<FixtureId, string> = {
  default: "test/fixtures/bench_input.png",
  character_kanata: "test/fixtures/bench_fixture_character_kanata.png",
  character_chika: "test/fixtures/bench_fixture_character_chika.png",
  landscape_sunbeach: "test/fixtures/bench_fixture_landscape_sunbeach.png",
  landscape_sea: "test/fixtures/bench_fixture_landscape_sea.png",
  landscape_study: "test/fixtures/bench_fixture_landscape_study.png",
};

const ALIASES: Record<string, FixtureId> = {
  character: "character_chika",
  landscape_wide: "landscape_sunbeach",
  landscape_soft: "landscape_sea",
};

export function resolveFixturePath(raw: string | undefined): { id: FixtureId; path: string } {
  const key = (raw?.trim().toLowerCase() || "default") as string;
  const resolved = (ALIASES[key] ?? key) as string;
  if (!FIXTURE_IDS.includes(resolved as FixtureId)) {
    throw new Error(
      `BENCH_FIXTURE="${raw}" は無効です。次のいずれか: ${FIXTURE_IDS.join(", ")}（別名: character→character_chika, landscape_wide→landscape_sunbeach, landscape_soft→landscape_sea）`,
    );
  }
  const id = resolved as FixtureId;
  return { id, path: join(REPO_ROOT, RELATIVE[id]) };
}
