import { execFile } from "child_process";
import { promisify } from "util";

const run = promisify(execFile);
const DOMAIN = "io.github.efeshinkawa.packlight";

export type Mode = "home" | "away";

export interface Estimate {
  percent?: number;
  onAC?: boolean;
  watts?: number;
  minutesLeft?: number;
  health?: number;
  cycles?: number;
  cpu?: number;
  memUsedGB?: number;
  memTotalGB?: number;
  topConsumers?: string[];
  tips?: string[];
}

export interface State {
  mode: Mode;
  estimate: Estimate;
  lastReport: string[];
  lastReportDate?: Date;
  settings: Record<string, boolean | number | string>;
}

/** Reads the Packlight app's preferences through cfprefsd, so values are always fresh. */
export async function readState(): Promise<State> {
  const { stdout } = await run("/bin/sh", [
    "-c",
    `/usr/bin/defaults export ${DOMAIN} - | /usr/bin/plutil -convert json -o - -`,
  ]);
  const raw = JSON.parse(stdout) as Record<string, unknown>;
  const ts = typeof raw.lastReportDate === "number" ? raw.lastReportDate : 0;
  return {
    mode: raw.mode === "away" ? "away" : "home",
    estimate: (raw.estimate ?? {}) as Estimate,
    lastReport: Array.isArray(raw.lastReport) ? (raw.lastReport as string[]) : [],
    lastReportDate: ts > 0 ? new Date(ts * 1000) : undefined,
    settings: raw as Record<string, boolean | number | string>,
  };
}

/** Sends a command to Packlight (launches it in the background if needed). */
export async function send(path: string, query?: Record<string, string>) {
  const qs = query ? "?" + new URLSearchParams(query).toString() : "";
  await run("/usr/bin/open", ["-g", `packlight://${path}${qs}`]);
}

export async function setSetting(key: string, value: boolean | number | string) {
  await send("set", { key, value: String(value) });
}

/** Waits until the app has finished a mode switch and written its report. */
export async function waitForReport(since: number, timeoutMs = 45_000): Promise<State | undefined> {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    await new Promise((r) => setTimeout(r, 700));
    const s = await readState().catch(() => undefined);
    if (s?.lastReportDate && s.lastReportDate.getTime() >= since - 500) return s;
  }
  return undefined;
}

export async function switchMode(mode: Mode | "toggle"): Promise<string> {
  const before = await readState().catch(() => undefined);
  const target: Mode = mode === "toggle" ? (before?.mode === "away" ? "home" : "away") : mode;
  const started = Date.now();
  await send(target);
  const after = await waitForReport(started);
  const label = target === "away" ? "Away mode" : "Home mode";
  return after ? `${label} · ${after.lastReport.join(" · ")}` : `${label} started`;
}

export function formatMinutes(m: number): string {
  const total = Math.round(m);
  return total >= 60 ? `${Math.floor(total / 60)}h ${total % 60}m` : `${total}m`;
}
